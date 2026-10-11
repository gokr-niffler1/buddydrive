import std/[json, options, os, sequtils, strutils, tables, unittest]
from std/times import fromUnix, toUnix
import chronos
import libp2p/stream/bridgestream
import ../../../src/buddydrive/types
import ../../../src/buddydrive/p2p/messages
import ../../../src/buddydrive/p2p/protocol
import ../../../src/buddydrive/sync/session
import ../../../src/buddydrive/sync/index
import ../../../src/buddydrive/sync/transfer
import ../../../src/buddydrive/crypto
from ../../../src/buddydrive/config import getIndexPath
import db_connector/db_sqlite
import ../../testutils
import ../../support/sync_fixtures

useIsolatedDataDir("session")

proc runBridgeSync(cfg1: AppConfig, cfg2: AppConfig, report: SessionReport = nil): Future[tuple[leftOk: bool, rightOk: bool]] {.async.} =
  let (left, right) = bridgedConnections(closeTogether = false)
  defer:
    await left.close()
    await right.close()

  let fut1 = syncBuddyFolders(cfg1, cfg1.buddies[0].id.uuid, left, newSyncProtocol(), report = report)
  let fut2 = syncBuddyFolders(cfg2, cfg2.buddies[0].id.uuid, right, newSyncProtocol())
  result.leftOk = await fut1
  result.rightOk = await fut2

proc syncBoth(cfg1, cfg2: AppConfig, report: SessionReport = nil) =
  let outcome = waitFor runBridgeSync(cfg1, cfg2, report)
  check outcome.leftOk
  check outcome.rightOk

proc syncCounting(cfg1, cfg2: AppConfig): tuple[ok: bool, received: int64] =
  ## Syncs once and returns how much file data the second side received.
  proc run(): Future[tuple[ok: bool, received: int64]] {.async.} =
    let (left, right) = bridgedConnections(closeTogether = false)
    defer:
      await left.close()
      await right.close()
    let storageSide = newSyncProtocol()
    let fut1 = syncBuddyFolders(cfg1, cfg1.buddies[0].id.uuid, left, newSyncProtocol())
    let fut2 = syncBuddyFolders(cfg2, cfg2.buddies[0].id.uuid, right, storageSide)
    let ok1 = await fut1
    let ok2 = await fut2
    result = (ok1 and ok2, storageSide.fileBytesReceived)
  waitFor run()

proc storedHashes(root: string): seq[string] =
  for path in storedFiles(root, ".meta"):
    result.add(parseJson(readFile(root / path))["hash"].getStr())

proc plainHash(path: string): string =
  hashToString(hashFileStream(path))

proc unkeyStoredHashes(root: string, folder: FolderConfig) =
  ## Rewrites the sidecars the way a buddy kept them before hashes were keyed.
  for path in storedFiles(root, ".meta"):
    let node = parseJson(readFile(root / path))
    let plainPath = decryptPath(node["encryptedPath"].getStr(), folder.folderKey)
    node["hash"] = %plainHash(folder.path / plainPath)
    writeFile(root / path, $node)

proc readBlobs(root: string): seq[string] =
  for path in storedFiles(root, ".blob"):
    result.add(readFile(root / path))

suite "Session sync":
  test "each buddy stores the other's folder encrypted, apart from its own":
    withTestDir("session_backup"):
      let folderA = testDir / "a"
      let folderB = testDir / "b"
      createDir(folderA / "nested")
      createDir(folderB)
      writeFile(folderA / "secret-plan.txt", "top secret\n")
      writeFile(folderA / "nested" / "notes.md", "private notes\n")
      writeFile(folderA / "empty.txt", "")
      writeFile(folderB / "b-own.txt", "belongs to B\n")

      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores",
        @[syncFolder("folder-a", folderA)])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores",
        @[syncFolder("folder-b", folderB)])

      syncBoth(cfgA, cfgB)

      # B's own docs folder is untouched by A's docs folder.
      check toSeq(walkDirRec(folderB, relative = true)) == @["b-own.txt"]
      check toSeq(walkDirRec(folderA, relative = true)).len == 3

      let storedAtB = testDir / "b-stores" / "folder-a"
      check storedFiles(storedAtB, ".blob").len == 3
      check storedFiles(storedAtB, ".meta").len == 3
      check not anyFileMentions(storedAtB, ["secret", "notes", "nested", "top secret", "private notes"])

      let storedAtA = testDir / "a-stores" / "folder-b"
      check storedFiles(storedAtA, ".blob").len == 1
      check not anyFileMentions(storedAtA, ["b-own", "belongs to B"])

  test "a second session transfers nothing new":
    withTestDir("session_idempotent"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "file.txt", "content\n")
      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])

      syncBoth(cfgA, cfgB)
      let before = readBlobs(testDir / "b-stores" / "folder-a")
      syncBoth(cfgA, cfgB)
      # Chunks get a fresh random nonce whenever they are sent, so an unchanged
      # blob proves nothing was sent again.
      check readBlobs(testDir / "b-stores" / "folder-a") == before

  test "lost files are restored from the buddy":
    withTestDir("session_restore"):
      let folderA = testDir / "a"
      createDir(folderA / "nested")
      createDir(testDir / "b")
      writeFile(folderA / "plan.txt", "the plan\n")
      writeFile(folderA / "nested" / "deep.bin", "\x00\x01\x02binary")
      writeFile(folderA / "empty.txt", "")
      when defined(posix):
        createSymlink("plan.txt", folderA / "plan-link")

      let source = syncFolder("folder-a", folderA)
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[source]), cfgB)

      # A new machine: same folder id and key, empty folder, no index.
      let restored = testDir / "restored"
      createDir(restored)
      var replacement = source
      replacement.path = restored
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[replacement]), cfgB)

      check readFile(restored / "plan.txt") == "the plan\n"
      check readFile(restored / "nested" / "deep.bin") == "\x00\x01\x02binary"
      check fileExists(restored / "empty.txt")
      check readFile(restored / "empty.txt") == ""
      when defined(posix):
        check symlinkExists(restored / "plan-link")
        check expandSymlink(restored / "plan-link") == "plan.txt"

  test "the buddy is told a keyed content hash, never the plain one":
    withTestDir("session_keyed_hash"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "known.txt", "a file the buddy might also have\n")
      let folder = syncFolder("folder-a", folderA)
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[folder]),
        peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")]))

      let hashes = storedHashes(testDir / "b-stores" / "folder-a")
      let plain = hashFileStream(folderA / "known.txt")
      check hashes == @[hashToString(keyedContentHash(plain, folder.folderKey))]
      check hashToString(plain) notin hashes

  test "a backup with plain hashes is rekeyed without sending the files again":
    withTestDir("session_rekey"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "one.txt", "one\n")
      writeFile(folderA / "two.txt", "two\n")
      let folder = syncFolder("folder-a", folderA)
      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[folder])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      syncBoth(cfgA, cfgB)
      let stored = testDir / "b-stores" / "folder-a"
      let keyed = storedHashes(stored)
      let blobs = readBlobs(stored)

      unkeyStoredHashes(stored, folder)
      check storedHashes(stored) != keyed
      let outcome = syncCounting(cfgA, cfgB)
      check outcome.ok
      check outcome.received == 0
      check storedHashes(stored) == keyed
      check readBlobs(stored) == blobs

  test "a file backed up with a plain hash can still be restored":
    withTestDir("session_restore_plain_hash"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "old.txt", "backed up long ago\n")
      let source = syncFolder("folder-a", folderA)
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[source]), cfgB)
      unkeyStoredHashes(testDir / "b-stores" / "folder-a", source)

      let restored = testDir / "restored"
      createDir(restored)
      var replacement = source
      replacement.path = restored
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[replacement]), cfgB)
      check readFile(restored / "old.txt") == "backed up long ago\n"

  test "a folder with the same id as another is skipped, not fatal":
    withTestDir("session_duplicate_id"):
      createDir(testDir / "first")
      createDir(testDir / "copy")
      createDir(testDir / "b")
      writeFile(testDir / "first" / "kept.txt", "kept\n")
      writeFile(testDir / "copy" / "other.txt", "other\n")
      let first = syncFolder("folder-a", testDir / "first", name = "first")
      var copy = syncFolder("folder-a", testDir / "copy", name = "copy")
      copy.folderKey = first.folderKey
      let report = SessionReport()
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[first, copy]),
        peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")]), report)

      check report.folders.anyIt(it.folderName == "copy" and it.outcome == foSkipped and "first" in it.reason)
      check report.folders.anyIt(it.folderName == "first" and it.outcome == foSynced)
      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 1

  test "renames move the stored blob instead of sending it again":
    withTestDir("session_move"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "old-name.txt", "same content\n")
      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      let storedAtB = testDir / "b-stores" / "folder-a"

      syncBoth(cfgA, cfgB)
      let before = storedFiles(storedAtB, ".blob")
      let blobBefore = readBlobs(storedAtB)

      moveFile(folderA / "old-name.txt", folderA / "new-name.txt")
      syncBoth(cfgA, cfgB)

      let after = storedFiles(storedAtB, ".blob")
      check after.len == 1
      check after != before
      check readBlobs(storedAtB) == blobBefore
      check not fileExists(folderA / "old-name.txt")

  test "edits and deletions reach the buddy's storage":
    withTestDir("session_edit_delete"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "edit.txt", "first\n")
      writeFile(folderA / "doomed.txt", "delete me\n")
      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      let storedAtB = testDir / "b-stores" / "folder-a"

      syncBoth(cfgA, cfgB)
      check storedFiles(storedAtB, ".blob").len == 2
      let blobsBefore = readBlobs(storedAtB)

      writeFile(folderA / "edit.txt", "second version\n")
      removeFile(folderA / "doomed.txt")
      syncBoth(cfgA, cfgB)

      check storedFiles(storedAtB, ".blob").len == 1
      check storedFiles(storedAtB, ".meta").len == 1
      check readBlobs(storedAtB)[0] notin blobsBefore
      check not fileExists(folderA / "doomed.txt")

      syncBoth(cfgA, cfgB)
      check not fileExists(folderA / "doomed.txt")

  test "append-only folders keep deleted files at the buddy without bringing them back":
    withTestDir("session_append_only"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "keeper.txt", "keep me\n")
      let source = syncFolder("folder-a", folderA, appendOnly = true)
      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[source])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      let storedAtB = testDir / "b-stores" / "folder-a"

      syncBoth(cfgA, cfgB)
      removeFile(folderA / "keeper.txt")
      syncBoth(cfgA, cfgB)
      syncBoth(cfgA, cfgB)

      check storedFiles(storedAtB, ".blob").len == 1
      check not fileExists(folderA / "keeper.txt")

      let restored = testDir / "restored"
      createDir(restored)
      var replacement = source
      replacement.path = restored
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[replacement]), cfgB)
      check readFile(restored / "keeper.txt") == "keep me\n"

  test "unencrypted folders are stored as plain files":
    withTestDir("session_plain"):
      let folderA = testDir / "a"
      createDir(folderA / "sub")
      createDir(testDir / "b")
      writeFile(folderA / "sub" / "shared.txt", "shared data\n")
      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores",
        @[syncFolder("folder-a", folderA, name = "shared", encrypted = false)])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])

      syncBoth(cfgA, cfgB)

      check readFile(testDir / "b-stores" / "folder-a" / "sub" / "shared.txt") == "shared data\n"

  test "an encrypted folder without a key is never sent":
    withTestDir("session_no_key"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "secret.txt", "top secret\n")
      var keyless = syncFolder("folder-a", folderA)
      keyless.folderKey = ""
      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[keyless])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])

      syncBoth(cfgA, cfgB)

      check not dirExists(testDir / "b-stores" / "folder-a")
      check not anyFileMentions(testDir / "b-stores", ["secret"])

  proc twoFolderSetup(testDir: string): tuple[cfgA, cfgB: AppConfig, one, two: string] =
    result.one = testDir / "one"
    result.two = testDir / "two"
    createDir(result.one)
    createDir(result.two)
    createDir(testDir / "b")
    writeFile(result.one / "keep-1.txt", "first\n")
    writeFile(result.one / "keep-2.txt", "second\n")
    writeFile(result.two / "other.txt", "other\n")
    result.cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores",
      @[syncFolder("folder-one", result.one, name = "one"), syncFolder("folder-two", result.two, name = "two")])
    result.cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])

  test "a missing folder is skipped and its backup kept":
    # An unplugged disk used to scan as an empty folder, which told the
    # buddy to delete every stored file of it.
    withTestDir("session_missing_folder"):
      let setup = twoFolderSetup(testDir)
      syncBoth(setup.cfgA, setup.cfgB)
      let storedOne = testDir / "b-stores" / "folder-one"
      let before = readBlobs(storedOne)
      check before.len == 2

      moveDir(setup.one, testDir / "unplugged")
      writeFile(setup.two / "new.txt", "new\n")
      let report = SessionReport()
      syncBoth(setup.cfgA, setup.cfgB, report)

      check report.folders.len == 2
      check report.folders.anyIt(it.folderName == "one" and it.outcome == foSkipped and it.reason.len > 0)
      check report.folders.anyIt(it.folderName == "two" and it.outcome == foSynced)
      check readBlobs(storedOne) == before
      check storedFiles(testDir / "b-stores" / "folder-two", ".blob").len == 2

  when defined(posix):
    test "an unreadable folder is skipped and the others still sync":
      withTestDir("session_unreadable_folder"):
        let setup = twoFolderSetup(testDir)
        syncBoth(setup.cfgA, setup.cfgB)
        let storedOne = testDir / "b-stores" / "folder-one"
        let before = readBlobs(storedOne)

        setFilePermissions(setup.one, {})
        try:
          writeFile(setup.two / "new.txt", "new\n")
          syncBoth(setup.cfgA, setup.cfgB)
        finally:
          setFilePermissions(setup.one, {fpUserRead, fpUserWrite, fpUserExec})

        check readBlobs(storedOne) == before
        check storedFiles(testDir / "b-stores" / "folder-two", ".blob").len == 2

    test "an unreadable file holds back its folder rather than leaking its name":
      withTestDir("session_unreadable_file"):
        let setup = twoFolderSetup(testDir)
        syncBoth(setup.cfgA, setup.cfgB)
        let storedOne = testDir / "b-stores" / "folder-one"
        let before = readBlobs(storedOne)

        writeFile(setup.one / "locked-secret-name.txt", "locked\n")
        setFilePermissions(setup.one / "locked-secret-name.txt", {})
        try:
          syncBoth(setup.cfgA, setup.cfgB)
        finally:
          setFilePermissions(setup.one / "locked-secret-name.txt", {fpUserRead, fpUserWrite})

        check readBlobs(storedOne) == before
        check not anyFileMentions(testDir / "b-stores", ["locked-secret-name"])

  when defined(posix):
    test "a renamed encrypted symlink is moved, and a changed target is noticed":
      withTestDir("session_symlink_move"):
        let folderA = testDir / "a"
        createDir(folderA)
        createDir(testDir / "b")
        writeFile(folderA / "target.txt", "target\n")
        createSymlink("target.txt", folderA / "link-old")
        let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)])
        let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
        let storedAtB = testDir / "b-stores" / "folder-a"

        proc sealedTargets(): seq[string] =
          for path in storedFiles(storedAtB, ".meta"):
            let target = parseJson(readFile(storedAtB / path)){"symlinkTarget"}.getStr("")
            if target.len > 0:
              result.add(target)

        syncBoth(cfgA, cfgB)
        let before = sealedTargets()
        check before.len == 1

        # A move keeps the sealed target as stored; fetching the link again
        # would seal it anew with a fresh random nonce.
        moveFile(folderA / "link-old", folderA / "link-new")
        syncBoth(cfgA, cfgB)
        check sealedTargets() == before

        removeFile(folderA / "link-new")
        writeFile(folderA / "other.txt", "other\n")
        createSymlink("other.txt", folderA / "link-new")
        syncBoth(cfgA, cfgB)
        check sealedTargets().len == 1
        check sealedTargets() != before

  test "a damaged blob is reported, not trusted with a huge allocation":
    withTestDir("session_damaged_blob"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "good.txt", "good\n")
      writeFile(folderA / "bad.txt", "bad\n")
      let source = syncFolder("folder-a", folderA)
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[source]), cfgB)

      # Make one blob's first frame claim a 4 GiB payload.
      let storedAtB = testDir / "b-stores" / "folder-a"
      var damaged = ""
      for path in storedFiles(storedAtB, ".blob"):
        var bytes = readFile(storedAtB / path)
        if damaged.len == 0:
          for i in 5 .. 8:
            bytes[i] = char(0xff)
          writeFile(storedAtB / path, bytes)
          damaged = path

      let restored = testDir / "restored"
      createDir(restored)
      var replacement = source
      replacement.path = restored
      syncBoth(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[replacement]), cfgB)

      # One of the two comes back; the damaged one does not, and nothing else breaks.
      var back = 0
      for name in ["good.txt", "bad.txt"]:
        if fileExists(restored / name):
          inc back
      check back == 1
  proc syncPair(owner: AppConfig, buddyId: string, buddy: AppConfig) =
    proc run(): Future[tuple[leftOk: bool, rightOk: bool]] {.async.} =
      let (left, right) = bridgedConnections(closeTogether = false)
      defer:
        await left.close()
        await right.close()
      let fut1 = syncBuddyFolders(owner, buddyId, left, newSyncProtocol())
      let fut2 = syncBuddyFolders(buddy, buddy.buddies[0].id.uuid, right, newSyncProtocol())
      result.leftOk = await fut1
      result.rightOk = await fut2
    let outcome = waitFor run()
    check outcome.leftOk
    check outcome.rightOk

  test "a delete reaches every buddy before its tombstone goes":
    # One index serves all the buddies of a folder. Clearing a deleted file's
    # row after the first buddy heard of it made the second buddy look like it
    # held a file we never had, so the file was restored from there.
    withTestDir("session_two_buddies"):
      const BuddyThree = "33333333-3333-3333-3333-333333333333"
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      createDir(testDir / "c")
      writeFile(folderA / "doomed.txt", "delete me\n")
      writeFile(folderA / "kept.txt", "keep me\n")

      var cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores-b", @[syncFolder("folder-a", folderA)])
      var third: BuddyInfo
      third.id = newBuddyId(BuddyThree, "peer-3333")
      third.storagePath = testDir / "a-stores-c"
      cfgA.buddies.add(third)
      cfgA.folders[0].buddies = @[]
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      let cfgC = peerConfig(BuddyThree, BuddyOne, testDir / "c-stores", @[syncFolder("folder-c", testDir / "c")])

      syncPair(cfgA, BuddyTwo, cfgB)
      syncPair(cfgA, BuddyThree, cfgC)
      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 2
      check storedFiles(testDir / "c-stores" / "folder-a", ".blob").len == 2

      removeFile(folderA / "doomed.txt")
      syncPair(cfgA, BuddyTwo, cfgB)
      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 1

      syncPair(cfgA, BuddyThree, cfgC)
      check not fileExists(folderA / "doomed.txt")
      check storedFiles(testDir / "c-stores" / "folder-a", ".blob").len == 1

      # Both have confirmed now; nothing comes back from either.
      syncPair(cfgA, BuddyTwo, cfgB)
      syncPair(cfgA, BuddyThree, cfgC)
      check not fileExists(folderA / "doomed.txt")
      check fileExists(folderA / "kept.txt")

  test "a file deleted, recreated and deleted again still reaches every buddy":
    withTestDir("session_delete_twice"):
      const BuddyThree = "33333333-3333-3333-3333-333333333333"
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      createDir(testDir / "c")
      writeFile(folderA / "flip.txt", "v1\n")

      var cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores-b", @[syncFolder("folder-a", folderA)])
      var third: BuddyInfo
      third.id = newBuddyId(BuddyThree, "peer-3333")
      cfgA.buddies.add(third)
      cfgA.folders[0].buddies = @[]
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      let cfgC = peerConfig(BuddyThree, BuddyOne, testDir / "c-stores", @[syncFolder("folder-c", testDir / "c")])

      syncPair(cfgA, BuddyTwo, cfgB)
      syncPair(cfgA, BuddyThree, cfgC)
      removeFile(folderA / "flip.txt")
      syncPair(cfgA, BuddyTwo, cfgB)            # B confirms the first delete
      writeFile(folderA / "flip.txt", "v2\n")   # back before C heard of it
      syncPair(cfgA, BuddyTwo, cfgB)
      syncPair(cfgA, BuddyThree, cfgC)
      removeFile(folderA / "flip.txt")
      syncPair(cfgA, BuddyThree, cfgC)          # only C confirms the second delete
      syncPair(cfgA, BuddyTwo, cfgB)            # B's old confirmation must not count

      check not fileExists(folderA / "flip.txt")
      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 0
      check storedFiles(testDir / "c-stores" / "folder-a", ".blob").len == 0

  test "renaming a folder keeps its deletes":
    # The index was keyed by the folder's name, so a rename lost every
    # tombstone and a deleted file came back from a buddy that had not
    # heard of the delete yet.
    withTestDir("session_rename_folder"):
      const BuddyThree = "33333333-3333-3333-3333-333333333333"
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      createDir(testDir / "c")
      writeFile(folderA / "doomed.txt", "delete me\n")
      writeFile(folderA / "kept.txt", "keep me\n")

      var cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores-b", @[syncFolder("folder-a", folderA)])
      var third: BuddyInfo
      third.id = newBuddyId(BuddyThree, "peer-3333")
      third.storagePath = testDir / "a-stores-c"
      cfgA.buddies.add(third)
      cfgA.folders[0].buddies = @[]
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      let cfgC = peerConfig(BuddyThree, BuddyOne, testDir / "c-stores", @[syncFolder("folder-c", testDir / "c")])

      syncPair(cfgA, BuddyTwo, cfgB)
      syncPair(cfgA, BuddyThree, cfgC)
      removeFile(folderA / "doomed.txt")
      syncPair(cfgA, BuddyTwo, cfgB)            # B hears of the delete
      cfgA.folders[0].name = "renamed"
      syncPair(cfgA, BuddyThree, cfgC)          # C has not yet

      check not fileExists(folderA / "doomed.txt")
      check storedFiles(testDir / "c-stores" / "folder-a", ".blob").len == 1
      syncPair(cfgA, BuddyTwo, cfgB)
      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 1

  test "an index kept under the folder's name and path still drives deletes":
    withTestDir("session_legacy_index"):
      let folderA = testDir / "a"
      createDir(folderA)
      createDir(testDir / "b")
      writeFile(folderA / "doomed.txt", "delete me\n")
      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])
      syncBoth(cfgA, cfgB)

      # Keyed as an older build left it.
      let db = open(getIndexPath(), "", "", "")
      db.exec(sql"UPDATE files SET folder = ? WHERE folder = ?",
        cfgA.folders[0].name & "|" & folderA, indexKey(cfgA.folders[0]))
      db.close()

      removeFile(folderA / "doomed.txt")
      syncBoth(cfgA, cfgB)
      check not fileExists(folderA / "doomed.txt")
      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 0

  proc syncAs(owner: AppConfig, buddy: AppConfig, machine: string, takeover = false, report: SessionReport = nil) =
    proc run(): Future[tuple[leftOk: bool, rightOk: bool]] {.async.} =
      let (left, right) = bridgedConnections(closeTogether = false)
      defer:
        await left.close()
        await right.close()
      let fut1 = syncBuddyFolders(owner, owner.buddies[0].id.uuid, left, newSyncProtocol(),
        ownerMachine = machine, takeover = takeover, report = report)
      let fut2 = syncBuddyFolders(buddy, buddy.buddies[0].id.uuid, right, newSyncProtocol())
      result.leftOk = await fut1
      result.rightOk = await fut2
    let outcome = waitFor run()
    check outcome.leftOk
    check outcome.rightOk

  proc twoMachines(testDir: string): tuple[old, new, buddy: AppConfig, oldDir, newDir: string] =
    ## Two installations with one buddy identity and the same folder (id and
    ## key), as after recovering onto a new machine.
    result.oldDir = testDir / "old-machine"
    result.newDir = testDir / "new-machine"
    createDir(result.oldDir)
    createDir(result.newDir)
    createDir(testDir / "b")
    let folder = syncFolder("folder-a", result.oldDir)
    var moved = folder
    moved.path = result.newDir
    result.old = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[folder])
    result.new = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[moved])
    result.buddy = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", testDir / "b")])

  test "a second machine with the same identity is refused":
    withTestDir("session_second_owner"):
      let m = twoMachines(testDir)
      writeFile(m.oldDir / "from-old.txt", "old\n")
      syncAs(m.old, m.buddy, "machine-old")
      let stored = testDir / "b-stores" / "folder-a"
      let before = readBlobs(stored)
      check before.len == 1

      writeFile(m.newDir / "from-new.txt", "new\n")
      let report = SessionReport()
      syncAs(m.new, m.buddy, "machine-new", report = report)

      check report.folders.len == 1
      check report.folders[0].outcome == foRefused
      check report.folders[0].reason.len > 0
      check readBlobs(stored) == before
      check not fileExists(m.newDir / "from-old.txt")
      check fileExists(m.newDir / "from-new.txt")

  test "takeover hands the folder to the new machine and refuses the old one":
    withTestDir("session_takeover"):
      let m = twoMachines(testDir)
      writeFile(m.oldDir / "from-old.txt", "old\n")
      syncAs(m.old, m.buddy, "machine-old")
      let stored = testDir / "b-stores" / "folder-a"

      syncAs(m.new, m.buddy, "machine-new", takeover = true)
      # The new machine restores what the old one had backed up.
      check readFile(m.newDir / "from-old.txt") == "old\n"
      let afterTakeover = readBlobs(stored)

      writeFile(m.oldDir / "late-change.txt", "old machine is still running\n")
      syncAs(m.old, m.buddy, "machine-old")
      check readBlobs(stored) == afterTakeover

      # Without asking again, the new machine keeps owning it.
      writeFile(m.newDir / "next.txt", "next\n")
      syncAs(m.new, m.buddy, "machine-new")
      check readBlobs(stored).len == afterTakeover.len + 1

  test "a buddy's file list cannot reach outside its storage folder":
    withTestDir("session_traversal"):
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[])

      proc run(cfg: AppConfig): Future[bool] {.async.} =
        let (left, right) = bridgedConnections(closeTogether = false)
        defer:
          await left.close()
          await right.close()
        let protocol = newSyncProtocol()
        let syncFut = syncBuddyFolders(cfg, BuddyOne, left, protocol)

        # Scripted owner with an unencrypted folder that tries to escape.
        let evil = FileEntry(path: "../../escaped.txt", encryptedPath: "../../escaped.txt",
          size: 4, mtime: 1, hash: "00", mode: 0o644)
        await protocol.sendMessage(right, newFileList("shared", @[evil], "../evil", encrypted = false))
        await protocol.sendMessage(right, newSyncDone())
        discard await protocol.receiveMessage(right)
        # Owner round: nothing to change, then serve whatever is asked for.
        await protocol.sendMessage(right, newListPathsRequest("../evil"))
        discard await protocol.receiveMessage(right)
        await protocol.sendMessage(right, newSyncDone())
        while true:
          let msg = await protocol.receiveMessage(right)
          if msg.isNone or msg.get().kind != msgFileRequest:
            break
          await protocol.sendMessage(right, newFileData(@[byte(1), 2, 3, 4], 0, 4, true))
          discard await protocol.receiveMessage(right)
        await protocol.sendMessage(right, newSessionEnd())
        discard await protocol.receiveMessage(right)
        result = await syncFut

      check waitFor run(cfgB)
      check not fileExists(testDir / "escaped.txt")
      check not fileExists(testDir / "b-stores" / "escaped.txt")
      for path in walkDirRec(testDir, relative = true):
        check "escaped" notin path

  proc bytesOf(s: string): seq[byte] =
    @(s.toOpenArrayByte(0, s.high))

  proc scriptedOwnerSync(cfg: AppConfig, folderId: string, entries: seq[FileEntry],
      contents: Table[string, string]): bool =
    ## Plays an owner with one unencrypted folder against the real storage
    ## side in cfg, serving whatever it asks for from contents.
    proc run(): Future[bool] {.async.} =
      let (left, right) = bridgedConnections(closeTogether = false)
      defer:
        await left.close()
        await right.close()
      let protocol = newSyncProtocol()
      let syncFut = syncBuddyFolders(cfg, BuddyOne, left, protocol)
      await protocol.sendMessage(right, newFileList("shared", entries, folderId, encrypted = false))
      await protocol.sendMessage(right, newSyncDone())
      discard await protocol.receiveMessage(right)
      await protocol.sendMessage(right, newListPathsRequest(folderId))
      discard await protocol.receiveMessage(right)
      await protocol.sendMessage(right, newSyncDone())
      while true:
        let msg = await protocol.receiveMessage(right)
        if msg.isNone or msg.get().kind != msgFileRequest:
          break
        let data = bytesOf(contents.getOrDefault(msg.get().requestPath))
        await protocol.sendMessage(right, newFileData(data, 0, data.len, true))
        discard await protocol.receiveMessage(right)
      await protocol.sendMessage(right, newSessionEnd())
      discard await protocol.receiveMessage(right)
      result = await syncFut
    waitFor run()

  test "a buddy cannot reach outside its storage folder through a symlink":
    # Unencrypted folders are stored as real files, symlinks included. A link
    # named like our temp file for another file used to be written through
    # when that file arrived, and a link listed again as a file with the same
    # hash had its target's mode and time changed.
    withTestDir("session_symlink_escape"):
      let victim = testDir / "victim.txt"
      writeFile(victim, "original\n")
      setFilePermissions(victim, {fpUserRead, fpUserWrite})
      setLastModificationTime(victim, fromUnix(1_000_000))
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[])

      proc fileEntry(path, content: string, mode = 0o644): FileEntry =
        FileEntry(path: path, encryptedPath: path, size: content.len, mtime: 2_000_000,
          hash: hashToString(hashBytes(bytesOf(content))), mode: mode)
      proc linkEntry(path, target: string): FileEntry =
        FileEntry(path: path, encryptedPath: path, size: target.len, mtime: 2_000_000,
          hash: hashToString(hashBytes(bytesOf(target))), symlinkTarget: target)

      check scriptedOwnerSync(cfgB, "shared-id",
        @[fileEntry("a", "first\n"), linkEntry("a.buddytmp", victim), linkEntry("link", victim)],
        {"a": "first\n"}.toTable)
      check scriptedOwnerSync(cfgB, "shared-id",
        @[fileEntry("a", "pwned\n"), fileEntry("link", victim, mode = 0o777)],
        {"a": "pwned\n", "link": victim}.toTable)

      check readFile(victim) == "original\n"
      check getFilePermissions(victim) == {fpUserRead, fpUserWrite}
      check getLastModificationTime(victim).toUnix() == 1_000_000
      let stored = testDir / "b-stores" / "shared-id"
      check readFile(stored / "a") == "pwned\n"
      check not symlinkExists(stored / "a.buddytmp")
      check not symlinkExists(stored / "link")
      check readFile(stored / "link") == victim

suite "Stalled buddy":
  test "a buddy that goes silent mid-session is given up on":
    withTestDir("session_stalled"):
      let saved = (messageIdleTimeout, folderListTimeout)
      messageIdleTimeout = chronos.milliseconds(300)
      folderListTimeout = chronos.milliseconds(300)
      defer:
        messageIdleTimeout = saved[0]
        folderListTimeout = saved[1]
      let cfg = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[])

      proc run(cfg: AppConfig): Future[bool] {.async.} =
        let (left, right) = bridgedConnections(closeTogether = false)
        defer:
          await left.close()
          await right.close()
        let protocol = newSyncProtocol()
        let syncFut = syncBuddyFolders(cfg, BuddyTwo, left, protocol)
        # The buddy offers a folder for us to store, then never asks anything.
        await protocol.sendMessage(right, newFileList("docs", @[], "folder-x", encrypted = true))
        await protocol.sendMessage(right, newSyncDone())
        discard await protocol.receiveMessage(right)
        return await syncFut.wait(chronos.seconds(20))

      check not waitFor run(cfg)

  test "a buddy that never sends its folder lists is given up on":
    withTestDir("session_silent"):
      let saved = folderListTimeout
      folderListTimeout = chronos.milliseconds(300)
      defer: folderListTimeout = saved
      let cfg = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[])

      proc run(cfg: AppConfig): Future[bool] {.async.} =
        let (left, right) = bridgedConnections(closeTogether = false)
        defer:
          await left.close()
          await right.close()
        let protocol = newSyncProtocol()
        let syncFut = syncBuddyFolders(cfg, BuddyTwo, left, protocol)
        discard await protocol.receiveMessage(right)
        try:
          return await syncFut.wait(chronos.seconds(20))
        except CatchableError:
          return false

      check not waitFor run(cfg)

suite "Session end":
  test "waits for the buddy before finishing":
    # The side that finishes first used to close straight away, cutting off a
    # buddy that was still reading the tail of a transfer through a relay. It
    # must now announce the end and wait for the buddy to do the same.
    withTestDir("session_end"):
      var cfg = newAppConfig(newBuddyId("11111111-1111-1111-1111-111111111111", "buddy-one"))
      var buddy: BuddyInfo
      buddy.id = newBuddyId("22222222-2222-2222-2222-222222222222", "buddy-two")
      cfg.buddies = @[buddy]

      proc run(cfg: AppConfig): Future[tuple[sawSessionEnd: bool, waitedForUs: bool, ok: bool]] {.async.} =
        let (left, right) = bridgedConnections(closeTogether = false)
        defer:
          await left.close()
          await right.close()

        let protocol = newSyncProtocol()
        let syncFut = syncBuddyFolders(cfg, cfg.buddies[0].id.uuid, left, protocol)

        # Scripted buddy: no folders either, so the conversation is just the
        # empty folder-list exchange followed by the session end.
        let listDone = await protocol.receiveMessage(right)
        if listDone.isNone or listDone.get().kind != msgSyncDone:
          return (false, false, false)
        await protocol.sendMessage(right, newSyncDone())

        let ending = await protocol.receiveMessage(right)
        result.sawSessionEnd = ending.isSome and ending.get().kind == msgSessionEnd

        await sleepAsync(chronos.milliseconds(200))
        result.waitedForUs = not syncFut.finished

        await protocol.sendMessage(right, newSessionEnd())
        result.ok = await syncFut

      let outcome = waitFor run(cfg)
      check outcome.sawSessionEnd
      check outcome.waitedForUs
      check outcome.ok

  test "finishes when the buddy never sends session end":
    # An older buddy does not know the message; the session must still succeed.
    withTestDir("session_end_old_peer"):
      var cfg = newAppConfig(newBuddyId("11111111-1111-1111-1111-111111111111", "buddy-one"))
      var buddy: BuddyInfo
      buddy.id = newBuddyId("22222222-2222-2222-2222-222222222222", "buddy-two")
      cfg.buddies = @[buddy]

      proc run(cfg: AppConfig): Future[bool] {.async.} =
        let (left, right) = bridgedConnections(closeTogether = false)
        let protocol = newSyncProtocol()
        let syncFut = syncBuddyFolders(cfg, cfg.buddies[0].id.uuid, left, protocol)

        let listDone = await protocol.receiveMessage(right)
        if listDone.isNone or listDone.get().kind != msgSyncDone:
          return false
        await protocol.sendMessage(right, newSyncDone())

        # Buddy hangs up without a session end, as an older build would.
        await right.close()
        result = await syncFut
        await left.close()

      check waitFor run(cfg)
