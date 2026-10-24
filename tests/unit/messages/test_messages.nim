import std/unittest
import std/times
import ../../../src/buddydrive/p2p/messages

suite "Integer encoding":
  test "encodeInt int64 big-endian":
    let data = encodeInt(0x0102030405060708'i64)
    check data.len == 8
    check data[0] == byte(0x01)
    check data[7] == byte(0x08)

  test "encodeInt uint32 big-endian":
    let data = encodeInt(0x01020304'u32)
    check data.len == 4
    check data[0] == byte(0x01)
    check data[3] == byte(0x04)

  test "readInt64 reads big-endian":
    let data = @[byte(0), 0, 0, 0, 0, 0, 0, 5]
    check readInt64(data, 0) == 5

  test "readUint32 reads big-endian":
    let data = @[byte(0), 0, 0, 42]
    check readUint32(data, 0) == 42

  test "encodeInt/decodeInt64 round-trip":
    let val = 0x1122334455667788'i64
    let data = encodeInt(val)
    check readInt64(data, 0) == val

suite "FileList message":
  test "encode/decode round-trip":
    let msg = newFileList("myfolder", @[
      FileEntry(path: "a.txt", encryptedPath: "enc_a", size: 100, mtime: 1000, hash: "abc123", mode: 0o644, symlinkTarget: ""),
      FileEntry(path: "b.txt", encryptedPath: "enc_b", size: 200, mtime: 2000, hash: "def456", mode: 0o777, symlinkTarget: "target.txt")
    ])
    let encoded = encode(msg)
    check encoded.len > 0
    let decoded = decode(encoded)
    check decoded.isOk
    let d = decoded.get()
    check d.kind == msgFileList
    check d.folderName == "myfolder"
    check d.files.len == 2
    check d.files[0].path == "a.txt"
    check d.files[0].encryptedPath == "enc_a"
    check d.files[0].size == 100
    check d.files[1].hash == "def456"
    check d.files[1].mode == 0o777
    check d.files[1].symlinkTarget == "target.txt"

  test "empty file list":
    let msg = newFileList("empty", @[])
    let encoded = encode(msg)
    let decoded = decode(encoded)
    check decoded.isOk
    check decoded.get().files.len == 0

suite "FileRequest message":
  test "encode/decode round-trip":
    let msg = newFileRequest("dir/file.txt", offset = 1024, length = 4096)
    let encoded = encode(msg)
    let decoded = decode(encoded)
    check decoded.isOk
    let d = decoded.get()
    check d.kind == msgFileRequest
    check d.requestPath == "dir/file.txt"
    check d.requestOffset == 1024
    check d.requestLength == 4096

  test "default offset and length":
    let msg = newFileRequest("file.txt")
    check msg.requestOffset == 0
    check msg.requestLength == -1

suite "FileData message":
  test "encode/decode round-trip":
    let data = @[byte(1), 2, 3, 4, 5]
    let msg = newFileData(data, offset = 0, totalSize = 100, done = false, compression = ckNone, originalLen = 5)
    let encoded = encode(msg)
    let decoded = decode(encoded)
    check decoded.isOk
    let d = decoded.get()
    check d.kind == msgFileData
    check d.data == data
    check d.dataOffset == 0
    check d.totalSize == 100
    check d.done == false
    check d.dataCompression == ckNone
    check d.dataOriginalLen == 5

  test "FileData with LZ4 compression":
    let data = @[byte(10), 20, 30]
    let msg = newFileData(data, offset = 3, totalSize = 50, done = true, compression = ckLz4, originalLen = 100)
    let encoded = encode(msg)
    let decoded = decode(encoded)
    check decoded.isOk
    let d = decoded.get()
    check d.dataCompression == ckLz4
    check d.dataOriginalLen == 100
    check d.done == true

  test "FileData done flag":
    let data = @[byte(42)]
    let msg = newFileData(data, offset = 0, totalSize = 1, done = true)
    let encoded = encode(msg)
    let decoded = decode(encoded)
    check decoded.get().done == true

suite "FileAck message":
  test "success ack round-trip":
    let msg = newFileAck(true, bytesReceived = 4096)
    let encoded = encode(msg)
    let decoded = decode(encoded)
    check decoded.isOk
    let d = decoded.get()
    check d.kind == msgFileAck
    check d.success == true
    check d.bytesReceived == 4096

  test "failure ack":
    let msg = newFileAck(false)
    let decoded = decode(encode(msg))
    check decoded.get().success == false

suite "FileDelete message":
  test "encode/decode round-trip":
    let msg = newFileDelete("old_file.txt")
    let decoded = decode(encode(msg))
    check decoded.isOk
    check decoded.get().kind == msgFileDelete
    check decoded.get().deletedPath == "old_file.txt"

suite "MoveFile message":
  test "encode/decode round-trip":
    let msg = newMoveFile("old.txt", "new.txt", "abc123")
    let decoded = decode(encode(msg))
    check decoded.isOk
    check decoded.get().kind == msgMoveFile
    check decoded.get().oldPath == "old.txt"
    check decoded.get().newPath == "new.txt"
    check decoded.get().moveHash == "abc123"

  test "carries folder id and flags":
    let msg = newFileList("docs", @[], "5eafb7a6-62af-400f-b961-288209be18b8", encrypted = true, appendOnly = true)
    let decoded = decode(encode(msg))
    check decoded.isOk
    check decoded.get().folderName == "docs"
    check decoded.get().folderId == "5eafb7a6-62af-400f-b961-288209be18b8"
    check decoded.get().folderEncrypted
    check decoded.get().folderAppendOnly

  test "flags default to off":
    let decoded = decode(encode(newFileList("docs", @[])))
    check decoded.isOk
    check not decoded.get().folderEncrypted
    check not decoded.get().folderAppendOnly

  test "carries the owner's machine and takeover flag":
    let decoded = decode(encode(newFileList("docs", @[], "id-1", ownerMachine = "machine-1", takeover = true)))
    check decoded.isOk
    check decoded.get().ownerMachine == "machine-1"
    check decoded.get().ownerTakeover

suite "FolderRefused message":
  test "round-trip":
    let decoded = decode(encode(newFolderRefused("id-1", "owned by another machine")))
    check decoded.isOk
    check decoded.get().kind == msgFolderRefused
    check decoded.get().refusedFolderId == "id-1"
    check decoded.get().refusedReason == "owned by another machine"

suite "Rehash message":
  test "round-trip":
    let decoded = decode(encode(newRehash("enc-path", "abc123")))
    check decoded.isOk
    check decoded.get().kind == msgRehash
    check decoded.get().rehashPath == "enc-path"
    check decoded.get().rehashHash == "abc123"

suite "ListPaths messages":
  test "request round-trip":
    let msg = newListPathsRequest("folder")
    let decoded = decode(encode(msg))
    check decoded.isOk
    check decoded.get().kind == msgListPathsRequest
    check decoded.get().listFolderId == "folder"

  test "response round-trip":
    let msg = newListPathsResponse("folder", @[
      FileEntry(path: "a.txt", encryptedPath: "enc_a", size: 1, mtime: 2, hash: "h1", mode: 0o644, symlinkTarget: ""),
      FileEntry(path: "link", encryptedPath: "enc_link", size: 6, mtime: 3, hash: "h2", mode: 0o777, symlinkTarget: "target"),
    ])
    let decoded = decode(encode(msg))
    check decoded.isOk
    check decoded.get().kind == msgListPathsResponse
    check decoded.get().listResponseFolderId == "folder"
    check decoded.get().listFiles.len == 2
    check decoded.get().listFiles[1].path == "link"
    check decoded.get().listFiles[1].encryptedPath == "enc_link"
    check decoded.get().listFiles[1].symlinkTarget == "target"

suite "Ping/Pong messages":
  test "ping round-trip":
    let msg = newPing()
    check msg.kind == msgPing
    check msg.timestamp > 0
    let decoded = decode(encode(msg))
    check decoded.isOk
    check decoded.get().kind == msgPing

  test "pong round-trip":
    let ts = getTime().toUnix()
    let msg = newPong(ts)
    let decoded = decode(encode(msg))
    check decoded.isOk
    check decoded.get().kind == msgPong
    check decoded.get().pingTimestamp == ts

suite "SyncDone message":
  test "encode/decode round-trip":
    let msg = newSyncDone()
    let encoded = encode(msg)
    let decoded = decode(encoded)
    check decoded.isOk
    check decoded.get().kind == msgSyncDone

suite "SessionEnd message":
  test "encode/decode round-trip":
    let msg = newSessionEnd()
    let encoded = encode(msg)
    let decoded = decode(encoded)
    check decoded.isOk
    check decoded.get().kind == msgSessionEnd

  test "kind byte is appended, so existing kinds keep their values":
    # Older buddies must still decode every message they already knew.
    check ord(msgFileList) == 0
    check ord(msgSyncDone) == ord(msgSessionEnd) - 1

suite "Decode edge cases":
  test "too-short data returns error":
    let decoded = decode(@[byte(0)])
    check decoded.isErr

  test "invalid message kind returns error":
    let decoded = decode(@[byte(99), byte(ProtocolVersion)])
    check decoded.isErr

  test "wrong protocol version returns error":
    let msg = newSyncDone()
    var encoded = encode(msg)
    encoded[1] = byte(99)
    let decoded = decode(encoded)
    check decoded.isErr

  test "truncated FileList returns error":
    let msg = newFileList("folder", @[FileEntry(path: "a.txt", encryptedPath: "enc", size: 1, mtime: 1, hash: "x", mode: 0o644, symlinkTarget: "")])
    var encoded = encode(msg)
    let truncated = encoded[0 ..< encoded.len - 5]
    let decoded = decode(truncated)
    check decoded.isErr
