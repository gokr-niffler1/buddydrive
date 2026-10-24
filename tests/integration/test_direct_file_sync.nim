import std/[os, unittest]
import chronos
import libp2p
import ../../src/buddydrive/types
import ../../src/buddydrive/daemon
import ../../src/buddydrive/p2p/node
import ../../src/buddydrive/p2p/pairing
import ../../src/buddydrive/p2p/protocol
import ../../src/buddydrive/sync/session
import ../support/integration_harness
import ../support/sync_fixtures
import ../testutils

useIsolatedDataDir("direct_file_sync")

proc dialAndSync(cfg: AppConfig, listener: BuddyNode, port: int): Future[bool] {.async.} =
  let node = newBuddyNode(port)
  await node.start()
  defer: await node.stop()

  let conn = await node.switch.dial(listener.peerId, listener.getAddrs(), PairingProtocol)
  let bc = newBuddyConnection()
  bc.conn = conn
  if not await bc.performHandshake(cfg):
    return false
  result = await syncBuddyFolders(cfg, bc.buddyId, conn, newSyncProtocol())
  await bc.close()

suite "Direct file sync":
  test "a full session runs over an incoming libp2p connection":
    # The daemon's handler for incoming connections used to start the sync in
    # the background and return, and libp2p closes a stream as soon as its
    # handler returns. Relay connections do not go through that handler, so
    # only a real dial shows it.
    withTestDir("direct_sync"):
      let folderA = testDir / "a"
      let folderB = testDir / "b"
      createDir(folderA)
      createDir(folderB)
      writeFile(folderA / "from-a.txt", "a secret\n")
      writeFile(folderB / "from-b.txt", "b secret\n")

      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", folderB)])

      let listener = newDaemon(cfgB)
      listener.node = newBuddyNode(freePort())
      waitFor listener.node.start()
      listener.syncProtocol = newSyncProtocol(listener.node)
      waitFor listener.mountPairingProtocol()
      defer: waitFor listener.node.stop()

      check waitFor dialAndSync(cfgA, listener.node, freePort())

      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 1
      check storedFiles(testDir / "a-stores" / "folder-b", ".blob").len == 1
      check not anyFileMentions(testDir / "b-stores", ["from-a", "a secret"])
