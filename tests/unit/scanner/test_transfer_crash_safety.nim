import std/[options, os, unittest]
from std/times import fromUnix, toUnix
import chronos
import libp2p/stream/bufferstream
import libp2p/stream/bridgestream
import ../../../src/buddydrive/types
import ../../../src/buddydrive/crypto
import ../../../src/buddydrive/p2p/messages
import ../../../src/buddydrive/p2p/protocol
import ../../../src/buddydrive/sync/transfer
import ../../../src/buddydrive/sync/scanner
import ../../testutils

useIsolatedDataDir("transfer_crash_safety")

proc feedMessages(
    sender: BridgeStream,
    protocol: SyncProtocol,
    msgs: seq[ProtocolMessage],
) {.async.} =
  for msg in msgs:
    await protocol.sendMessage(sender, msg)

proc answerListPaths(
    sender: BridgeStream,
    protocol: SyncProtocol,
    response: ProtocolMessage,
) {.async.} =
  let requestOpt = await protocol.receiveMessage(sender)
  doAssert requestOpt.isSome()
  doAssert requestOpt.get().kind == msgListPathsRequest
  await protocol.sendMessage(sender, response)

proc newTestTransfer(rootPath: string): FileTransfer =
  let folder = newFolderConfig("docs", rootPath)
  result = newFileTransfer(folder, newSyncProtocol())

proc newEncryptedTestTransfer(rootPath: string, folderKey: string): FileTransfer =
  var folder = newFolderConfig("docs", rootPath)
  folder.encrypted = true
  folder.folderKey = folderKey
  result = newFileTransfer(folder, newSyncProtocol())

suite "transfer crash safety":
  test "interrupted receive removes temp file and does not create final file":
    withTestDir("transfer_interrupt"):
      let (sender, receiver) = bridgedConnections(closeTogether = false)
      let transfer = newTestTransfer(testDir)
      defer:
        transfer.close()

      let msg = newFileData(@[byte(1), 2, 3, 4], 0, 8, false, ckNone, 4)
      let receiveFut = transfer.receiveFileData(receiver, "nested/file.bin")
      waitFor feedMessages(sender, transfer.protocol, @[msg])
      waitFor receiver.pushEof()
      let ackFut = transfer.protocol.receiveMessage(sender)

      let ok = waitFor receiveFut
      let ackOpt = waitFor ackFut
      check not ok
      check ackOpt.isSome()
      check ackOpt.get().kind == msgFileAck
      check not ackOpt.get().success
      check not fileExists(testDir / "nested" / "file.bin")
      check not fileExists(testDir / "nested" / ("file.bin" & TempSuffix))

  test "mismatched total size fails receive and leaves no committed file":
    withTestDir("transfer_totalsize"):
      let (sender, receiver) = bridgedConnections(closeTogether = false)
      let transfer = newTestTransfer(testDir)
      defer:
        transfer.close()

      let msg1 = newFileData(@[byte(1), 2, 3, 4], 0, 8, false, ckNone, 4)
      let msg2 = newFileData(@[byte(5), 6, 7, 8], 4, 7, true, ckNone, 4)
      let receiveFut = transfer.receiveFileData(receiver, "file.bin")
      waitFor feedMessages(sender, transfer.protocol, @[msg1, msg2])
      let ackFut = transfer.protocol.receiveMessage(sender)

      let ok = waitFor receiveFut
      let ackOpt = waitFor ackFut
      check not ok
      check ackOpt.isSome()
      check ackOpt.get().kind == msgFileAck
      check not ackOpt.get().success
      check not fileExists(testDir / "file.bin")
      check not fileExists(testDir / ("file.bin" & TempSuffix))

  test "flush failure prevents rename and cleans temp file":
    withTestDir("transfer_flushfail"):
      let (sender, receiver) = bridgedConnections(closeTogether = false)
      let transfer = newTestTransfer(testDir)
      defer:
        setFlushAndCloseShouldFail(false)
        transfer.close()

      setFlushAndCloseShouldFail(true)

      let msg = newFileData(@[byte(1), 2, 3, 4], 0, 4, true, ckNone, 4)
      let receiveFut = transfer.receiveFileData(receiver, "file.bin")
      waitFor feedMessages(sender, transfer.protocol, @[msg])
      let ackFut = transfer.protocol.receiveMessage(sender)

      let ok = waitFor receiveFut
      let ackOpt = waitFor ackFut
      check not ok
      check ackOpt.isSome()
      check ackOpt.get().kind == msgFileAck
      check not ackOpt.get().success
      check not fileExists(testDir / "file.bin")
      check not fileExists(testDir / ("file.bin" & TempSuffix))

  test "successful receive commits final file":
    withTestDir("transfer_success"):
      let (sender, receiver) = bridgedConnections(closeTogether = false)
      let transfer = newTestTransfer(testDir)
      defer:
        transfer.close()

      let msg1 = newFileData(@[byte(1), 2], 0, 4, false, ckNone, 2)
      let msg2 = newFileData(@[byte(3), 4], 2, 4, true, ckNone, 2)
      var fileInfo: types.FileInfo
      fileInfo.path = "ok.bin"
      fileInfo.mtime = 1_700_000_000
      fileInfo.mode = 0o640
      let receiveFut = transfer.receiveFileData(receiver, fileInfo)
      waitFor feedMessages(sender, transfer.protocol, @[msg1, msg2])
      let ackFut = transfer.protocol.receiveMessage(sender)

      let ok = waitFor receiveFut
      let ackOpt = waitFor ackFut
      check ok
      check ackOpt.isSome()
      check ackOpt.get().kind == msgFileAck
      check ackOpt.get().success
      check fileExists(testDir / "ok.bin")
      check not fileExists(testDir / ("ok.bin" & TempSuffix))
      let content = readFile(testDir / "ok.bin")
      check content.len == 4
      check content[0] == char(1)
      check content[3] == char(4)
      let scanned = transfer.scanner.scanFile(testDir / "ok.bin")
      check scanned.mode == 0o640
      check scanned.mtime == 1_700_000_000

  when defined(posix):
    test "a symlink left at the temp path is replaced, not written through":
      withTestDir("transfer_temp_symlink"):
        let victim = testDir / "victim.txt"
        writeFile(victim, "original\n")
        createDir(testDir / "root")
        createSymlink(victim, testDir / "root" / ("file.bin" & TempSuffix))
        let (sender, receiver) = bridgedConnections(closeTogether = false)
        let transfer = newTestTransfer(testDir / "root")
        defer:
          transfer.close()

        let msg = newFileData(@[byte(1), 2, 3, 4], 0, 4, true, ckNone, 4)
        let receiveFut = transfer.receiveFileData(receiver, "file.bin")
        waitFor feedMessages(sender, transfer.protocol, @[msg])
        let ackFut = transfer.protocol.receiveMessage(sender)

        check waitFor receiveFut
        discard waitFor ackFut
        check readFile(victim) == "original\n"
        check readFile(testDir / "root" / "file.bin") == "\x01\x02\x03\x04"
        check not symlinkExists(testDir / "root" / "file.bin")

    test "file metadata is never applied through a symlink":
      withTestDir("transfer_metadata_symlink"):
        let victim = testDir / "victim.txt"
        writeFile(victim, "original\n")
        setFilePermissions(victim, {fpUserRead, fpUserWrite})
        setLastModificationTime(victim, fromUnix(1_000_000))
        createSymlink(victim, testDir / "link")
        var info: types.FileInfo
        info.mode = 0o777
        info.mtime = 2_000_000
        applyFileMetadata(testDir / "link", info)
        check getFilePermissions(victim) == {fpUserRead, fpUserWrite}
        check getLastModificationTime(victim).toUnix() == 1_000_000

  test "receiveFileData fails on hash mismatch and removes final file":
    withTestDir("transfer_hash_mismatch"):
      discard initCrypto()
      let (sender, receiver) = bridgedConnections(closeTogether = false)
      let transfer = newTestTransfer(testDir)
      defer:
        transfer.close()

      let msg = newFileData(@[byte(1), 2, 3, 4], 0, 4, true, ckNone, 4)
      var fileInfo: types.FileInfo
      fileInfo.path = "bad.bin"
      for i in 0..<32:
        fileInfo.hash[i] = byte(255 - i)
      let receiveFut = transfer.receiveFileData(receiver, fileInfo)
      waitFor feedMessages(sender, transfer.protocol, @[msg])
      let ackFut = transfer.protocol.receiveMessage(sender)

      check not waitFor receiveFut
      let ackOpt = waitFor ackFut
      check ackOpt.isSome()
      check ackOpt.get().kind == msgFileAck
      check not ackOpt.get().success
      check not fileExists(testDir / "bad.bin")

  test "encrypted sendFileData encrypts chunk payload":
    withTestDir("transfer_send_encrypted"):
      discard initCrypto()
      let key = generateKey()
      let (sender, receiver) = bridgedConnections(closeTogether = false)
      let transfer = newEncryptedTestTransfer(testDir, key)
      defer:
        transfer.close()
        waitFor sender.close()
        waitFor receiver.close()

      let plainBytes = @[byte(1), 2, 3, 4, 5]
      writeFile(testDir / "secret.bin", "\x01\x02\x03\x04\x05")

      let sendFut = transfer.sendFileData(receiver, "secret.bin", 0, -1)
      let msgOpt = waitFor transfer.protocol.receiveMessage(sender)
      check msgOpt.isSome()
      check msgOpt.get().kind == msgFileData
      check msgOpt.get().data != plainBytes
      let decrypted = decryptChunk(msgOpt.get().data, key)
      check decrypted == plainBytes
      waitFor transfer.protocol.sendMessage(sender, newFileAck(true, 5))
      check waitFor sendFut

  test "encrypted receiveFileData decrypts chunk payload":
    withTestDir("transfer_receive_encrypted"):
      discard initCrypto()
      let key = generateKey()
      let (sender, receiver) = bridgedConnections(closeTogether = false)
      let transfer = newEncryptedTestTransfer(testDir, key)
      defer:
        transfer.close()

      let plainBytes = @[byte(9), 8, 7, 6]
      let encryptedBytes = encryptChunk(plainBytes, key)
      let msg = newFileData(encryptedBytes, 0, 4, true, ckNone, 4)
      var fileInfo: types.FileInfo
      fileInfo.path = "secret.bin"
      let receiveFut = transfer.receiveFileData(receiver, fileInfo)
      waitFor feedMessages(sender, transfer.protocol, @[msg])
      let ackFut = transfer.protocol.receiveMessage(sender)

      check waitFor receiveFut
      let ackOpt = waitFor ackFut
      check ackOpt.isSome()
      check ackOpt.get().success
      let content = readFile(testDir / "secret.bin")
      check content.len == 4
      check content[0] == char(9)
      check content[3] == char(6)

when defined(posix):
  suite "transfer metadata handling":
    test "symlink sync restores link from metadata":
      withTestDir("transfer_symlink"):
        let (sender, receiver) = bridgedConnections(closeTogether = false)
        let transfer = newTestTransfer(testDir)
        defer:
          transfer.close()
          waitFor sender.close()
          waitFor receiver.close()

        var fileInfo: types.FileInfo
        fileInfo.path = "link.txt"
        fileInfo.symlinkTarget = "target.txt"
        fileInfo.mtime = 1_700_000_001
        let ok = waitFor transfer.syncFile(receiver, fileInfo)
        check ok
        check symlinkExists(testDir / "link.txt")
        check expandSymlink(testDir / "link.txt") == "target.txt"

suite "transfer local file operations":
  test "deleteLocalFile removes file and index entry":
    withTestDir("transfer_delete_local"):
      let transfer = newTestTransfer(testDir)
      defer:
        transfer.close()

      writeFile(testDir / "delete.txt", "delete me")
      transfer.index.addFile(transfer.scanner.scanFile(testDir / "delete.txt"), synced = true)
      check transfer.index.getFile("delete.txt").isSome()
      check transfer.deleteLocalFile("delete.txt")
      check not fileExists(testDir / "delete.txt")
      check transfer.index.getFile("delete.txt").isNone()

  test "moveLocalFile renames file and updates index":
    withTestDir("transfer_move_local"):
      let transfer = newTestTransfer(testDir)
      defer:
        transfer.close()

      writeFile(testDir / "old.txt", "move me")
      transfer.index.addFile(transfer.scanner.scanFile(testDir / "old.txt"), synced = true)
      check transfer.moveLocalFile("old.txt", "nested/new.txt")
      check not fileExists(testDir / "old.txt")
      check fileExists(testDir / "nested" / "new.txt")
      check transfer.index.getFile("old.txt").isNone()
      check transfer.index.getFile("nested/new.txt").isSome()

  test "rebuildIndexFromDisk repopulates missing cache entries":
    withTestDir("transfer_rebuild_index"):
      let transfer = newTestTransfer(testDir)
      defer:
        transfer.close()

      writeFile(testDir / "present.txt", "hello")
      check transfer.index.getFile("present.txt").isNone()
      transfer.rebuildIndexFromDisk()
      check transfer.index.getFile("present.txt").isSome()

suite "transfer list paths":
  test "requestListPaths decodes list response":
    withTestDir("transfer_list_paths"):
      let (sender, receiver) = bridgedConnections(closeTogether = false)
      let transfer = newTestTransfer(testDir)
      defer:
        transfer.close()
        waitFor sender.close()
        waitFor receiver.close()

      let response = newListPathsResponse("docs", @[
        FileEntry(path: "a.txt", encryptedPath: "enc_a", size: 10, mtime: 20, hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", mode: 0o644, symlinkTarget: ""),
        FileEntry(path: "link", encryptedPath: "enc_link", size: 6, mtime: 21, hash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", mode: 0o777, symlinkTarget: "target"),
      ])

      let listFut = transfer.requestListPaths(receiver)
      waitFor answerListPaths(sender, transfer.protocol, response)
      let filesOpt = waitFor listFut
      check filesOpt.isSome()
      check filesOpt.get().len == 2
      check filesOpt.get()[0].path == "a.txt"
      check filesOpt.get()[1].symlinkTarget == "target"
