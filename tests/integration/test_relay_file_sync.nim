import std/unittest
import std/os
import std/sequtils
import chronos
import ../../src/buddydrive/types
import ../../src/buddydrive/p2p/rawrelay
import ../../src/buddydrive/p2p/pairing
import ../../src/buddydrive/p2p/protocol
import ../../src/buddydrive/sync/session
import ../support/test_relay
import ../testutils
import ../support/sync_fixtures

useIsolatedDataDir("relay_file_sync")

proc relayConfig(
    selfId: string,
    otherId: string,
    storagePath: string,
    folders: seq[FolderConfig],
): AppConfig =
  result = peerConfig(selfId, otherId, storagePath, folders, pairingCode = "swift-eagle")
  result.relayRegion = "local"
  result.apiBaseUrl = ""

proc connectAndSync(config: AppConfig): Future[void] {.async.} =
  let cache = initRelayListCache()
  let relayConn = await connectViaRegionalRelay(
    cache,
    config.apiBaseUrl,
    config.relayRegion,
    config.buddies[0].pairingCode
  )
  let bc = newBuddyConnection()
  bc.conn = relayConn.conn
  doAssert await bc.performHandshake(config)
  let protocol = newSyncProtocol()
  doAssert await syncBuddyFolders(config, bc.buddyId, bc.conn, protocol)
  await bc.close()

proc syncPeers(cfg1, cfg2: AppConfig) =
  waitFor allFutures([connectAndSync(cfg1), connectAndSync(cfg2)])

proc freshDirs(base: string, names: varargs[string]): seq[string] =
  removeDir(base)
  for name in names:
    let dir = base / name
    createDir(dir)
    result.add(dir)

proc blobContents(root: string): seq[string] =
  for path in storedFiles(root, ".blob"):
    result.add(readFile(root / path))

suite "Relay file sync":
  var relay: TestRelay

  setup:
    relay = startTestRelay()

  teardown:
    waitFor relay.stop()

  test "both buddies back up their folders to each other in one session":
    let tempBase = getTempDir() / "buddydrive-relay-file-sync-both"
    let dirs = freshDirs(tempBase, "docs-a", "docs-b")
    defer:
      removeDir(tempBase)

    writeFile(dirs[0] / "from-a.txt", "a secret\n")
    writeFile(dirs[1] / "from-b.txt", "b secret\n")

    let cfgA = relayConfig(BuddyOne, BuddyTwo, tempBase / "a-stores", @[syncFolder("folder-a", dirs[0])])
    let cfgB = relayConfig(BuddyTwo, BuddyOne, tempBase / "b-stores", @[syncFolder("folder-b", dirs[1])])

    syncPeers(cfgA, cfgB)

    check toSeq(walkDirRec(dirs[0], relative = true)) == @["from-a.txt"]
    check toSeq(walkDirRec(dirs[1], relative = true)) == @["from-b.txt"]
    check storedFiles(tempBase / "b-stores" / "folder-a", ".blob").len == 1
    check storedFiles(tempBase / "a-stores" / "folder-b", ".blob").len == 1
    check not anyFileMentions(tempBase / "b-stores", ["from-a", "a secret"])
    check not anyFileMentions(tempBase / "a-stores", ["from-b", "b secret"])

  test "large file survives the relay and comes back intact":
    let tempBase = getTempDir() / "buddydrive-relay-file-sync-large"
    let dirs = freshDirs(tempBase, "docs-a", "docs-b", "restored")
    defer:
      removeDir(tempBase)

    var content = newString(300 * 1024)
    for i in 0 ..< content.len:
      content[i] = char((i * 7919) mod 251)
    writeFile(dirs[0] / "big.bin", content)

    let source = syncFolder("folder-a", dirs[0])
    let cfgB = relayConfig(BuddyTwo, BuddyOne, tempBase / "b-stores", @[syncFolder("folder-b", dirs[1])])
    syncPeers(relayConfig(BuddyOne, BuddyTwo, tempBase / "a-stores", @[source]), cfgB)

    var replacement = source
    replacement.path = dirs[2]
    syncPeers(relayConfig(BuddyOne, BuddyTwo, tempBase / "a-stores", @[replacement]), cfgB)

    check readFile(dirs[2] / "big.bin") == content

  test "rename, edit and deletion reach the buddy's storage":
    let tempBase = getTempDir() / "buddydrive-relay-file-sync-changes"
    let dirs = freshDirs(tempBase, "docs-a", "docs-b", "restored")
    defer:
      removeDir(tempBase)

    writeFile(dirs[0] / "old-name.txt", "same content\n")
    writeFile(dirs[0] / "edit.txt", "first\n")
    writeFile(dirs[0] / "doomed.txt", "delete me\n")

    let source = syncFolder("folder-a", dirs[0])
    let cfgA = relayConfig(BuddyOne, BuddyTwo, tempBase / "a-stores", @[source])
    let cfgB = relayConfig(BuddyTwo, BuddyOne, tempBase / "b-stores", @[syncFolder("folder-b", dirs[1])])
    let storedAtB = tempBase / "b-stores" / "folder-a"

    syncPeers(cfgA, cfgB)
    check storedFiles(storedAtB, ".blob").len == 3

    moveFile(dirs[0] / "old-name.txt", dirs[0] / "new-name.txt")
    writeFile(dirs[0] / "edit.txt", "second\n")
    removeFile(dirs[0] / "doomed.txt")
    syncPeers(cfgA, cfgB)
    check storedFiles(storedAtB, ".blob").len == 2

    var replacement = source
    replacement.path = dirs[2]
    syncPeers(relayConfig(BuddyOne, BuddyTwo, tempBase / "a-stores", @[replacement]), cfgB)
    check readFile(dirs[2] / "new-name.txt") == "same content\n"
    check readFile(dirs[2] / "edit.txt") == "second\n"
    check not fileExists(dirs[2] / "old-name.txt")
    check not fileExists(dirs[2] / "doomed.txt")

  test "encrypted and unencrypted folders side by side":
    let tempBase = getTempDir() / "buddydrive-relay-file-sync-mixed"
    let dirs = freshDirs(tempBase, "enc-a", "plain-a", "docs-b")
    defer:
      removeDir(tempBase)

    writeFile(dirs[0] / "secret.txt", "top secret\n")
    writeFile(dirs[1] / "shared.txt", "shared data\n")

    let cfgA = relayConfig(BuddyOne, BuddyTwo, tempBase / "a-stores", @[
      syncFolder("folder-enc", dirs[0], name = "encrypted-docs"),
      syncFolder("folder-plain", dirs[1], name = "shared-docs", encrypted = false),
    ])
    let cfgB = relayConfig(BuddyTwo, BuddyOne, tempBase / "b-stores", @[syncFolder("folder-b", dirs[2])])

    syncPeers(cfgA, cfgB)

    check storedFiles(tempBase / "b-stores" / "folder-enc", ".blob").len == 1
    check not anyFileMentions(tempBase / "b-stores" / "folder-enc", ["secret"])
    check readFile(tempBase / "b-stores" / "folder-plain" / "shared.txt") == "shared data\n"
