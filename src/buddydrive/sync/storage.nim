## The storage side of a sync: keeping a buddy's folder on our disk.
##
## Each buddy gets its own storage root (see buddyStorageRoot), and each folder
## they share with us lives in a directory under it named by the folder id, so
## their folders never mix with ours or with each other.
##
## Encrypted folders are stored as opaque blobs. A blob holds the chunks
## exactly as the owner sent them, still sealed with the owner's folder key, and
## a small sidecar holds what the owner told us about the file. Blob names are
## a hash of the encrypted path, so nothing on disk reveals the owner's file
## names. Unencrypted folders are stored as ordinary files so they can be
## browsed.

import std/os except FileInfo
import std/[json, options, strutils, algorithm, tables]
import chronos
import libp2p/stream/connection
import ../types
import ../config
import ../crypto
import ../p2p/messages
import ../p2p/protocol
import scanner
import index
import transfer

type
  StorageFolder* = ref object
    ownerId*: string
    folderId*: string
    folderName*: string
    encrypted*: bool
    appendOnly*: bool
    root*: string
    protocol*: SyncProtocol
    throttler*: Throttler
    plain*: FileTransfer

const
  BlobSuffix = ".blob"
  MaxFramePayload = 1024 * 1024
    ## A frame holds one chunk of at most TransferChunkSize bytes, sealed and
    ## possibly LZ4-compressed; this leaves ample room.
  MetaSuffix = ".meta"
  MaxDirNameLen = 128

proc toHexString(data: openArray[byte]): string =
  for b in data:
    result.add(b.toHex(2).toLowerAscii())

proc stringBytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for i, c in value:
    result[i] = byte(c)

proc digestHex(value: string): string {.raises: [IOError].} =
  try:
    toHexString(hashBytes(stringBytes(value)))[0 ..< 32]
  except Exception as e:
    raise newException(IOError, "hashing failed: " & e.msg)

proc storageDirName*(folderId: string): string =
  ## A folder id is normally a UUID; anything that is not a plain single path
  ## component is replaced by its hash.
  var safe = folderId.len > 0 and folderId.len <= MaxDirNameLen and
    folderId != "." and folderId != ".."
  for c in folderId:
    if not (c.isAlphaNumeric() or c in {'-', '_', '.'}):
      safe = false
  if safe:
    folderId
  else:
    "f-" & digestHex(folderId)

proc storageFolderRoot*(config: AppConfig, ownerId: string, folderId: string): string =
  config.buddyStorageRoot(ownerId) / storageDirName(folderId)

proc newStorageFolder*(
    config: AppConfig,
    ownerId: string,
    listing: ProtocolMessage,
    protocol: SyncProtocol,
): StorageFolder =
  result = StorageFolder()
  result.ownerId = ownerId
  result.folderId = listing.folderId
  result.folderName = listing.folderName
  result.encrypted = listing.folderEncrypted
  result.appendOnly = listing.folderAppendOnly
  result.root = config.storageFolderRoot(ownerId, listing.folderId)
  result.protocol = protocol
  result.throttler = newThrottler(config.bandwidthLimitKBps * 1024)
  createDir(result.root)
  if not result.encrypted:
    var folder = newFolderConfig("storage:" & ownerId & ":" & listing.folderId, result.root, encrypted = false)
    folder.appendOnly = result.appendOnly
    result.plain = newFileTransfer(folder, protocol, config.bandwidthLimitKBps)

proc close*(storage: StorageFolder) =
  if storage.plain != nil:
    storage.plain.close()

proc blobBase(storage: StorageFolder, encryptedPath: string): string =
  let name = digestHex(encryptedPath)
  storage.root / name[0 ..< 2] / name

proc blobPath(storage: StorageFolder, encryptedPath: string): string =
  storage.blobBase(encryptedPath) & BlobSuffix

proc metaPath(storage: StorageFolder, encryptedPath: string): string =
  storage.blobBase(encryptedPath) & MetaSuffix

proc writeMeta(path: string, info: FileInfo): bool {.raises: [].} =
  let node = %*{
    "encryptedPath": info.encryptedPath,
    "hash": hashToString(info.hash),
    "size": info.size,
    "mtime": info.mtime,
    "mode": info.mode,
    "symlinkTarget": info.symlinkTarget,
  }
  let tmpPath = path & TempSuffix
  try:
    createDir(path.parentDir())
    writeFile(tmpPath, $node)
    flushAndClose(tmpPath)
    moveFile(tmpPath, path)
    true
  except:
    try:
      removeFile(tmpPath)
    except:
      discard
    false

proc readMeta(path: string): Option[FileInfo] =
  try:
    let node = parseJson(readFile(path))
    var info: FileInfo
    info.encryptedPath = node["encryptedPath"].getStr()
    info.hash = stringToHash(node["hash"].getStr())
    info.size = node["size"].getBiggestInt()
    info.mtime = node["mtime"].getBiggestInt()
    info.mode = node["mode"].getInt()
    info.symlinkTarget = node{"symlinkTarget"}.getStr("")
    if info.encryptedPath.len == 0:
      return none(FileInfo)
    some(info)
  except CatchableError:
    none(FileInfo)

proc readStoredMeta(storage: StorageFolder, encryptedPath: string): Option[FileInfo] =
  let path = storage.metaPath(encryptedPath)
  if not fileExists(path):
    return none(FileInfo)
  let info = readMeta(path)
  if info.isNone or info.get().encryptedPath != encryptedPath:
    return none(FileInfo)
  if info.get().symlinkTarget.len == 0 and not fileExists(storage.blobPath(encryptedPath)):
    return none(FileInfo)
  info

proc listStored*(storage: StorageFolder): seq[FileInfo] =
  ## What we hold for the owner, as the owner described it to us.
  if storage.plain != nil:
    return storage.plain.scanner.scanDirectory()

  if not dirExists(storage.root):
    return @[]
  for path in walkDirRec(storage.root, relative = false):
    if not path.endsWith(MetaSuffix):
      continue
    let info = readMeta(path)
    if info.isNone:
      continue
    let stored = storage.readStoredMeta(info.get().encryptedPath)
    if stored.isSome:
      result.add(stored.get())
  result.sort(proc(a, b: FileInfo): int = cmp(a.encryptedPath, b.encryptedPath))

proc applyMove*(storage: StorageFolder, oldPath: string, newPath: string): bool {.raises: [].} =
  ## Renames a stored file on the owner's instruction. Append-only folders keep
  ## the old copy; the new path is fetched as a file of its own.
  if storage.appendOnly or oldPath == newPath:
    return true

  if storage.plain != nil:
    return storage.plain.moveLocalFile(oldPath, newPath)

  try:
    let stored = storage.readStoredMeta(oldPath)
    if stored.isNone:
      return true

    var info = stored.get()
    info.encryptedPath = newPath
    let oldBlob = storage.blobPath(oldPath)
    if fileExists(oldBlob):
      let newBlob = storage.blobPath(newPath)
      createDir(newBlob.parentDir())
      moveFile(oldBlob, newBlob)
    if not writeMeta(storage.metaPath(newPath), info):
      return false
    removeFile(storage.metaPath(oldPath))
    true
  except:
    false

proc applyDelete*(storage: StorageFolder, path: string): bool =
  if storage.appendOnly:
    return true

  if storage.plain != nil:
    return storage.plain.deleteLocalFile(path)

  try:
    removeFile(storage.metaPath(path))
    removeFile(storage.blobPath(path))
    true
  except CatchableError:
    false

proc writeFrame(f: File, msg: ProtocolMessage): bool =
  var header = newSeq[byte]()
  header.add(byte(msg.dataCompression))
  header.add(msg.dataOriginalLen.uint32.encodeInt())
  header.add(msg.data.len.uint32.encodeInt())
  try:
    if f.writeBytes(header, 0, header.len) != header.len:
      return false
    if msg.data.len > 0 and f.writeBytes(msg.data, 0, msg.data.len) != msg.data.len:
      return false
    true
  except CatchableError:
    false

proc receiveBlob(storage: StorageFolder, conn: Connection, info: FileInfo): Future[bool] {.async.} =
  ## Stores the owner's sealed chunks as they arrive, without opening them.
  let blobPath = storage.blobPath(info.encryptedPath)
  let tmpPath = blobPath & TempSuffix
  var file: File
  var opened = false
  var success = true
  var senderAborted = false
  var plainOffset: int64 = 0

  try:
    createDir(blobPath.parentDir())
    file = open(tmpPath, fmWrite)
    opened = true
  except CatchableError:
    success = false

  while true:
    let msgOpt = await storage.protocol.receiveMessage(conn)
    if msgOpt.isNone:
      success = false
      break
    let msg = msgOpt.get()
    if msg.kind == msgFileAck:
      senderAborted = true
      success = false
      break
    if msg.kind != msgFileData:
      success = false
      break

    if success:
      if msg.dataOffset != plainOffset or msg.totalSize != info.size or
          not writeFrame(file, msg):
        success = false
      else:
        plainOffset += msg.dataOriginalLen

    if msg.done:
      break

  if opened:
    try:
      file.close()
    except CatchableError:
      success = false

  if success and plainOffset != info.size:
    success = false

  if success:
    try:
      flushAndClose(tmpPath)
      moveFile(tmpPath, blobPath)
      success = writeMeta(storage.metaPath(info.encryptedPath), info)
    except:
      success = false

  if not success:
    try:
      removeFile(tmpPath)
    except CatchableError:
      discard

  if not senderAborted:
    try:
      await storage.protocol.sendMessage(conn, newFileAck(success, plainOffset))
    except CatchableError:
      discard

  return success

proc sendBlob(storage: StorageFolder, conn: Connection, encryptedPath: string): Future[bool] {.async.} =
  ## Streams a stored file back to its owner, chunk for chunk as it arrived.
  let stored = storage.readStoredMeta(encryptedPath)
  if stored.isNone or stored.get().symlinkTarget.len > 0:
    await storage.protocol.sendMessage(conn, newFileAck(false))
    return false
  let info = stored.get()
  let path = storage.blobPath(encryptedPath)

  var frames: seq[ProtocolMessage] = @[]
  try:
    let f = open(path, fmRead)
    defer: f.close()
    let fileSize = f.getFileSize()
    var plainOffset: int64 = 0
    var header = newSeq[byte](9)
    while f.getFilePos() < fileSize:
      if f.readBytes(header, 0, 9) != 9:
        raise newException(IOError, "truncated blob header")
      if header[0] > byte(ord(ckLz4)):
        raise newException(IOError, "invalid blob frame")
      let compression = CompressionKind(header[0])
      let originalLen = int(readUint32(header, 1))
      let payloadLen = int(readUint32(header, 5))
      # Check the length before trusting it with an allocation: a damaged blob
      # could otherwise ask for gigabytes.
      if payloadLen > MaxFramePayload or payloadLen.int64 > fileSize - f.getFilePos():
        raise newException(IOError, "damaged blob frame")
      var payload = newSeq[byte](payloadLen)
      if payloadLen > 0 and f.readBytes(payload, 0, payloadLen) != payloadLen:
        raise newException(IOError, "truncated blob payload")
      let done = f.getFilePos() >= fileSize
      frames.add(newFileData(payload, plainOffset, info.size, done, compression, originalLen))
      plainOffset += originalLen
      if frames.len > 1:
        try:
          await storage.protocol.sendMessage(conn, frames[0])
          await storage.throttler.throttle(frames[0].data.len)
        except CatchableError:
          return false
        frames.delete(0)
  except CatchableError:
    frames = @[]

  if frames.len == 0:
    await storage.protocol.sendMessage(conn, newFileAck(false))
    return false

  try:
    await storage.protocol.sendMessage(conn, frames[0])
  except CatchableError:
    return false

  let ackOpt = await storage.protocol.receiveMessage(conn)
  ackOpt.isSome and ackOpt.get().kind == msgFileAck and ackOpt.get().success

proc serveRestore*(storage: StorageFolder, conn: Connection, path: string, offset: int64, length: int): Future[bool] {.async.} =
  if storage.plain != nil:
    return await storage.plain.sendFileData(conn, path, offset, length)
  return await storage.sendBlob(conn, path)

proc filesToFetch*(storage: StorageFolder, ownerFiles: seq[FileInfo]): tuple[fetch: seq[FileInfo], metadata: seq[FileInfo]] =
  ## Compares the owner's list with what we hold. Changed content is fetched
  ## again; a change of mode or mtime alone only updates what we recorded.
  var stored = initTable[string, FileInfo]()
  for info in storage.listStored():
    stored[info.encryptedPath] = info

  var sorted = ownerFiles
  sorted.sort(proc(a, b: FileInfo): int = cmp(a.encryptedPath, b.encryptedPath))
  for info in sorted:
    if info.encryptedPath.len == 0:
      continue
    if info.encryptedPath notin stored:
      result.fetch.add(info)
      continue
    if storage.appendOnly:
      continue
    let held = stored[info.encryptedPath]
    if held.hash != info.hash or held.size != info.size:
      result.fetch.add(info)
    elif held.mode != info.mode or held.mtime != info.mtime or
        (storage.plain != nil and held.symlinkTarget != info.symlinkTarget):
      result.metadata.add(info)

proc storeFromOwner*(storage: StorageFolder, conn: Connection, info: FileInfo): Future[bool] {.async.} =
  if storage.plain != nil:
    var plainInfo = info
    plainInfo.path = info.encryptedPath
    return await storage.plain.syncFile(conn, plainInfo)

  if info.symlinkTarget.len > 0:
    try:
      removeFile(storage.blobPath(info.encryptedPath))
    except CatchableError:
      discard
    return writeMeta(storage.metaPath(info.encryptedPath), info)

  try:
    await storage.protocol.sendMessage(conn, newFileRequest(info.encryptedPath))
  except CatchableError:
    return false
  return await storage.receiveBlob(conn, info)

proc updateMetadata*(storage: StorageFolder, info: FileInfo): bool =
  if storage.plain != nil:
    let fullPath = safeJoin(storage.root, info.encryptedPath)
    if fullPath.isNone:
      return false
    var plainInfo = info
    plainInfo.path = info.encryptedPath
    applyFileMetadata(fullPath.get(), plainInfo)
    return true

  let stored = storage.readStoredMeta(info.encryptedPath)
  if stored.isNone:
    return false
  var updated = stored.get()
  updated.mode = info.mode
  updated.mtime = info.mtime
  writeMeta(storage.metaPath(info.encryptedPath), updated)
