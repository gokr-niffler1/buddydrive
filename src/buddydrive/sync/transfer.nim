import std/os except FileInfo
import std/options
import std/sets
import std/times
import std/base64
import results
import chronos
import lz4
import libp2p/stream/connection
import ../p2p/messages
import ../p2p/protocol
import ../crypto
import ../types
import scanner
import index

export results
export scanner
export index

type
  TransferError* = object of CatchableError
  
  Throttler* = ref object
    bytesPerSecond*: int
    lastTime*: Moment
    bytesSent*: int64
  
  FileTransfer* = ref object
    index*: FileIndex
    scanner*: FileScanner
    protocol*: SyncProtocol
    throttler*: Throttler

const
  TransferChunkSize* = 64 * 1024

proc newThrottler*(bytesPerSecond: int): Throttler =
  result = Throttler()
  result.bytesPerSecond = bytesPerSecond
  result.lastTime = Moment.now()
  result.bytesSent = 0

proc newFileTransfer*(folder: FolderConfig, protocol: SyncProtocol): FileTransfer =
  result = FileTransfer()
  result.index = newIndex(folder.name & "|" & folder.path)
  result.scanner = newFileScanner(folder, result.index)
  result.protocol = protocol
  result.throttler = newThrottler(0)

proc newFileTransfer*(folder: FolderConfig, protocol: SyncProtocol, bandwidthLimitKBps: int): FileTransfer =
  result = FileTransfer()
  result.index = newIndex(folder.name & "|" & folder.path)
  result.scanner = newFileScanner(folder, result.index)
  result.protocol = protocol
  result.throttler = newThrottler(bandwidthLimitKBps * 1024)

proc throttle*(t: Throttler, bytes: int) {.async.} =
  if t.bytesPerSecond <= 0:
    return
  
  let now = Moment.now()
  let elapsed = (now - t.lastTime).nanoseconds
  
  if elapsed >= 1_000_000_000:
    t.lastTime = now
    t.bytesSent = 0
  else:
    t.bytesSent += bytes
    let allowedBytes = (elapsed.int64 * t.bytesPerSecond.int64) div 1_000_000_000
    if t.bytesSent > allowedBytes:
      let excessBytes = t.bytesSent - allowedBytes
      let sleepNanos = (excessBytes * 1_000_000_000) div t.bytesPerSecond.int64
      if sleepNanos > 0:
        await sleepAsync(chronos.nanoseconds(sleepNanos))

proc close*(transfer: FileTransfer) =
  if transfer.index != nil:
    transfer.index.close()

proc hasExpectedHash(fileInfo: FileInfo): bool =
  for b in fileInfo.hash:
    if b != 0:
      return true
  false

proc rebuildIndexFromDisk*(transfer: FileTransfer) =
  ## Records every file currently on disk. Index rows for files that have
  ## disappeared are deliberately kept: they are the only evidence that we
  ## once held a path, which is what lets the delta tell a local deletion
  ## apart from a file we have simply never seen. Call
  ## pruneIndexOfMissingFiles once those deletions have been propagated.
  for fileInfo in transfer.scanner.scanDirectory():
    transfer.index.addFile(fileInfo, synced = true)

proc pruneIndexOfMissingFiles*(transfer: FileTransfer) =
  var onDisk: HashSet[string]
  for fileInfo in transfer.scanner.scanDirectory():
    onDisk.incl(fileInfo.path)

  for existing in transfer.index.getAllFiles():
    if existing.path notin onDisk:
      transfer.index.removeFile(existing.path)

proc knownIndexPaths*(transfer: FileTransfer): HashSet[string] =
  ## Paths this folder has held at some point, according to the index.
  for existing in transfer.index.getAllFiles():
    result.incl(existing.path)

proc verifyRestoredFile(transfer: FileTransfer, path: string, expected: FileInfo): bool =
  if not fileExists(path) and not symlinkExists(path):
    return false

  let actual = transfer.scanner.scanFile(path)
  if hasExpectedHash(expected) and actual.hash != expected.hash:
    return false
  if expected.symlinkTarget.len > 0 and actual.symlinkTarget != expected.symlinkTarget:
    return false
  if expected.mode != 0 and actual.mode != expected.mode:
    return false
  true

proc useEncryptedChunks(transfer: FileTransfer): bool =
  transfer.scanner.folder.encrypted and transfer.scanner.folder.folderKey.len == KeySize

proc modeToPermissions(mode: int): set[FilePermission] =
  if (mode and 0o400) != 0:
    result.incl(fpUserRead)
  if (mode and 0o200) != 0:
    result.incl(fpUserWrite)
  if (mode and 0o100) != 0:
    result.incl(fpUserExec)
  if (mode and 0o040) != 0:
    result.incl(fpGroupRead)
  if (mode and 0o020) != 0:
    result.incl(fpGroupWrite)
  if (mode and 0o010) != 0:
    result.incl(fpGroupExec)
  if (mode and 0o004) != 0:
    result.incl(fpOthersRead)
  if (mode and 0o002) != 0:
    result.incl(fpOthersWrite)
  if (mode and 0o001) != 0:
    result.incl(fpOthersExec)

proc applyFileMetadata*(path: string, fileInfo: FileInfo) {.raises: [].} =
  if fileInfo.symlinkTarget.len == 0 and fileInfo.mode != 0:
    try:
      setFilePermissions(path, modeToPermissions(fileInfo.mode))
    except:
      discard

  if fileInfo.mtime > 0:
    try:
      setLastModificationTime(path, fromUnix(fileInfo.mtime))
    except:
      discard

proc createSymlinkFile(path: string, fileInfo: FileInfo): bool {.raises: [].} =
  if fileInfo.symlinkTarget.len == 0:
    return false

  try:
    createDir(path.parentDir())
    if symlinkExists(path) or fileExists(path):
      removeFile(path)
    createSymlink(fileInfo.symlinkTarget, path)
    applyFileMetadata(path, fileInfo)
    true
  except:
    false

proc folderWireId*(folder: FolderConfig): string =
  ## Identifies a folder to the buddy. The stable id survives renames; the
  ## name is only a fallback for configs that predate folder ids.
  if folder.id.len > 0: folder.id else: folder.name

proc toFileEntry*(f: FileInfo): FileEntry =
  FileEntry(
    path: f.path,
    encryptedPath: f.encryptedPath,
    size: f.size,
    mtime: f.mtime,
    hash: hashToString(f.hash),
    mode: f.mode,
    symlinkTarget: f.symlinkTarget,
  )

proc toFileInfo*(entry: FileEntry): FileInfo =
  result.path = entry.path
  result.encryptedPath = entry.encryptedPath
  result.size = entry.size
  result.mtime = entry.mtime
  result.hash = stringToHash(entry.hash)
  result.mode = entry.mode
  result.symlinkTarget = entry.symlinkTarget

proc encryptSymlinkTarget(target: string, folderKey: string): string =
  var plain = newSeq[byte](target.len)
  for i, c in target:
    plain[i] = byte(c)
  let sealed = encryptChunk(plain, folderKey)
  var raw = newString(sealed.len)
  for i, b in sealed:
    raw[i] = char(b)
  base64.encode(raw)

proc decryptSymlinkTarget*(encrypted: string, folderKey: string): string =
  let raw = base64.decode(encrypted)
  var sealed = newSeq[byte](raw.len)
  for i, c in raw:
    sealed[i] = byte(c)
  let plain = decryptChunk(sealed, folderKey)
  result = newString(plain.len)
  for i, b in plain:
    result[i] = char(b)

proc isEncryptedOnWire*(transfer: FileTransfer): bool =
  transfer.useEncryptedChunks()

proc ownerFileEntries*(transfer: FileTransfer, files: seq[FileInfo]): seq[FileEntry] =
  ## What the storage buddy gets to see of our files. For encrypted folders
  ## that is the encrypted path, the content hash, size and metadata; the
  ## plaintext path is left out and symlink targets are sealed.
  for f in files:
    var entry = toFileEntry(f)
    if transfer.useEncryptedChunks():
      entry.path = ""
      if f.symlinkTarget.len > 0:
        try:
          entry.symlinkTarget = encryptSymlinkTarget(f.symlinkTarget, transfer.scanner.folder.folderKey)
        except CatchableError:
          continue
    result.add(entry)

proc sendFileList*(transfer: FileTransfer, conn: Connection, files: seq[FileInfo]): Future[bool] {.async.} =
  let folder = transfer.scanner.folder
  let msg = newFileList(
    folder.name,
    transfer.ownerFileEntries(files),
    folderWireId(folder),
    transfer.useEncryptedChunks(),
    folder.appendOnly,
  )

  try:
    await transfer.protocol.sendMessage(conn, msg)
    return true
  except:
    return false

proc sendFileList*(transfer: FileTransfer, conn: Connection): Future[bool] {.async.} =
  return await transfer.sendFileList(conn, transfer.scanner.scanDirectory())

proc receiveFileList*(transfer: FileTransfer, conn: Connection): Future[Option[seq[FileInfo]]] {.async.} =
  let msgOpt = await transfer.protocol.receiveMessage(conn)
  if msgOpt.isNone or msgOpt.get().kind != msgFileList:
    return none(seq[FileInfo])

  var files: seq[FileInfo] = @[]
  for entry in msgOpt.get().files:
    files.add(toFileInfo(entry))
  return some(files)

proc requestFile*(transfer: FileTransfer, conn: Connection, path: string, offset: int64 = 0, length: int = -1): Future[bool] {.async.} =
  let msg = newFileRequest(path, offset, length)
  
  try:
    await transfer.protocol.sendMessage(conn, msg)
    return true
  except:
    return false

proc receiveFileRequest*(transfer: FileTransfer, conn: Connection): Future[Option[tuple[path: string, offset: int64, length: int]]] {.async.} =
  let msgOpt = await transfer.protocol.receiveMessage(conn)
  if msgOpt.isNone or msgOpt.get().kind != msgFileRequest:
    return none((string, int64, int))
  
  let msg = msgOpt.get()
  return some((msg.requestPath, msg.requestOffset, msg.requestLength))

proc requestListPaths*(transfer: FileTransfer, conn: Connection): Future[Option[seq[FileInfo]]] {.async.} =
  ## Asks the storage buddy what it holds of this folder.
  let folderId = folderWireId(transfer.scanner.folder)
  try:
    await transfer.protocol.sendMessage(conn, newListPathsRequest(folderId))
  except CatchableError:
    return none(seq[FileInfo])

  let msgOpt = await transfer.protocol.receiveMessage(conn)
  if msgOpt.isNone or msgOpt.get().kind != msgListPathsResponse:
    return none(seq[FileInfo])

  let msg = msgOpt.get()
  if msg.listResponseFolderId != folderId:
    return none(seq[FileInfo])

  var files: seq[FileInfo] = @[]
  for entry in msg.listFiles:
    files.add(toFileInfo(entry))
  return some(files)

proc sendFileData*(transfer: FileTransfer, conn: Connection, path: string, offset: int64, length: int): Future[bool] {.async.} =
  let fullPathOpt = safeJoin(transfer.scanner.rootPath, path)
  if fullPathOpt.isNone or not fileExists(fullPathOpt.get()) or symlinkExists(fullPathOpt.get()):
    await transfer.protocol.sendMessage(conn, newFileAck(false))
    return false
  let fullPath = fullPathOpt.get()

  let fileSize = getFileSize(fullPath)

  if fileSize == 0 and offset == 0:
    var payload: seq[byte] = @[]
    if transfer.useEncryptedChunks():
      try:
        payload = encryptChunk(payload, transfer.scanner.folder.folderKey)
      except CatchableError:
        await transfer.protocol.sendMessage(conn, newFileAck(false))
        return false
    try:
      await transfer.protocol.sendMessage(conn, newFileData(payload, 0, 0, true, ckNone, 0))
    except:
      return false
  else:
    let actualLength = if length < 0: int(fileSize - offset) else: min(length, int(fileSize - offset))

    if actualLength <= 0:
      await transfer.protocol.sendMessage(conn, newFileAck(false))
      return false

    var currentOffset = offset
    var remaining = actualLength

    while remaining > 0:
      let chunkSize = min(remaining, TransferChunkSize)
      let data = readFileChunk(fullPath, currentOffset, chunkSize)

      if data.len == 0:
        await transfer.protocol.sendMessage(conn, newFileAck(false))
        return false

      let isDone = remaining <= chunkSize
      var payload = data
      var compression = ckNone
      try:
        let compressed = compress(data)
        if compressed.len > 0 and compressed.len < data.len:
          payload = compressed
          compression = ckLz4
      except CatchableError:
        discard

      if transfer.useEncryptedChunks():
        try:
          payload = encryptChunk(payload, transfer.scanner.folder.folderKey)
        except CatchableError:
          await transfer.protocol.sendMessage(conn, newFileAck(false))
          return false

      let msg = newFileData(payload, currentOffset, fileSize, isDone, compression, data.len)

      try:
        await transfer.protocol.sendMessage(conn, msg)
        await transfer.throttler.throttle(data.len)
      except:
        return false

      currentOffset += chunkSize
      remaining -= chunkSize

  let ackOpt = await transfer.protocol.receiveMessage(conn)
  if ackOpt.isNone or ackOpt.get().kind != msgFileAck:
    return false

  ackOpt.get().success

proc receiveFileData*(transfer: FileTransfer, conn: Connection, fileInfo: FileInfo): Future[bool] {.async.} =
  ## Receives one file and acknowledges it. A chunk that cannot be used fails
  ## the file but the rest of its chunks are still read, so the stream stays in
  ## step with the sender. A sender that gives up with an ack of its own gets
  ## no ack back.
  let fullPathOpt = safeJoin(transfer.scanner.rootPath, fileInfo.path)
  let fullPath = if fullPathOpt.isSome: fullPathOpt.get() else: ""
  let tmpPath = fullPath & TempSuffix

  var totalReceived: int64 = 0
  var expectedSize = int64(-1)
  var success = fullPathOpt.isSome
  var senderAborted = false

  if success:
    try:
      createDir(fullPath.parentDir())
    except CatchableError:
      success = false

  while true:
    let msgOpt = await transfer.protocol.receiveMessage(conn)
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

    if not success:
      if msg.done:
        break
      continue

    block chunk:
      if msg.dataOffset != totalReceived:
        success = false
        break chunk

      if expectedSize < 0:
        expectedSize = msg.totalSize
      elif msg.totalSize != expectedSize:
        success = false
        break chunk

      var payload = msg.data
      if transfer.useEncryptedChunks():
        try:
          payload = decryptChunk(payload, transfer.scanner.folder.folderKey)
        except CatchableError:
          success = false
          break chunk

      if msg.dataCompression == ckLz4:
        try:
          payload = decompress(payload, msg.dataOriginalLen)
        except CatchableError:
          success = false
          break chunk

      if not writeFileChunk(tmpPath, msg.dataOffset, payload):
        success = false
        break chunk

      totalReceived += payload.len

    if msg.done:
      break

  if success:
    if expectedSize >= 0 and totalReceived != expectedSize:
      success = false

  if success:
    try:
      flushAndClose(tmpPath)
      moveFile(tmpPath, fullPath)
      applyFileMetadata(fullPath, fileInfo)
    except:
      success = false

  if not success and fullPath.len > 0:
    try:
      removeFile(tmpPath)
    except:
      discard

  if success and (fileExists(fullPath) or symlinkExists(fullPath)):
    if transfer.verifyRestoredFile(fullPath, fileInfo):
      transfer.index.addFile(transfer.scanner.scanFile(fullPath), synced = true)
    else:
      success = false
      try:
        removeFile(fullPath)
      except:
        discard

  if not senderAborted:
    try:
      await transfer.protocol.sendMessage(conn, newFileAck(success, totalReceived))
    except:
      discard

  return success

proc receiveFileData*(transfer: FileTransfer, conn: Connection, path: string): Future[bool] {.async.} =
  var fileInfo: FileInfo
  fileInfo.path = path
  return await transfer.receiveFileData(conn, fileInfo)

proc restoreSymlink*(transfer: FileTransfer, fileInfo: FileInfo): bool =
  let fullPathOpt = safeJoin(transfer.scanner.rootPath, fileInfo.path)
  if fullPathOpt.isNone:
    return false
  let fullPath = fullPathOpt.get()
  if not createSymlinkFile(fullPath, fileInfo):
    return false
  if symlinkExists(fullPath):
    if transfer.verifyRestoredFile(fullPath, fileInfo):
      transfer.index.addFile(transfer.scanner.scanFile(fullPath), synced = true)
      return true
    try:
      removeFile(fullPath)
    except:
      discard
  false

proc syncFile*(transfer: FileTransfer, conn: Connection, fileInfo: FileInfo, requestPath = ""): Future[bool] {.async.} =
  ## Fetches one file from the buddy into this folder. requestPath is what the
  ## buddy knows the file as, when that differs from our own path.
  if safeJoin(transfer.scanner.rootPath, fileInfo.path).isNone:
    return false

  if fileInfo.symlinkTarget.len > 0:
    return transfer.restoreSymlink(fileInfo)

  let wirePath = if requestPath.len > 0: requestPath else: fileInfo.path
  if not await transfer.requestFile(conn, wirePath):
    return false
  
  return await transfer.receiveFileData(conn, fileInfo)

proc deleteLocalFile*(transfer: FileTransfer, path: string): bool {.raises: [].} =
  if transfer.scanner.folder.appendOnly:
    # Append-only folders never lose an existing local file to a remote
    # instruction. Report success so the session continues.
    return true

  let fullPathOpt = safeJoin(transfer.scanner.rootPath, path)
  if fullPathOpt.isNone:
    return false
  let fullPath = fullPathOpt.get()

  try:
    if symlinkExists(fullPath) or fileExists(fullPath):
      removeFile(fullPath)
    transfer.index.removeFile(path)
    return true
  except:
    return false

proc moveLocalFile*(transfer: FileTransfer, oldPath: string, newPath: string): bool {.raises: [].} =
  let oldFullPathOpt = safeJoin(transfer.scanner.rootPath, oldPath)
  let newFullPathOpt = safeJoin(transfer.scanner.rootPath, newPath)
  if oldFullPathOpt.isNone or newFullPathOpt.isNone:
    return false
  let oldFullPath = oldFullPathOpt.get()
  let newFullPath = newFullPathOpt.get()

  if not fileExists(oldFullPath) and not symlinkExists(oldFullPath):
    # Nothing to move; the file will be fetched under its new name instead.
    return true

  try:
    createDir(newFullPath.parentDir())
    moveFile(oldFullPath, newFullPath)
    transfer.index.removeFile(oldPath)
    transfer.index.addFile(transfer.scanner.scanFile(newFullPath), synced = true)
    return true
  except:
    return false
