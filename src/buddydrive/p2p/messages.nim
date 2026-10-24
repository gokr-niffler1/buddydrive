import std/times
import results
import chronos
import libp2p
import libp2p/stream/bufferstream

export results

type
  MessageKind* = enum
    msgFileList
    msgFileRequest
    msgFileData
    msgFileAck
    msgFileDelete
    msgMoveFile
    msgListPathsRequest
    msgListPathsResponse
    msgPing
    msgPong
    msgSyncDone
    msgSessionEnd
    msgFolderRefused
    msgRehash

  CompressionKind* = enum
    ckNone = 0
    ckLz4 = 1

  ProtocolMessage* = object
    case kind*: MessageKind
    of msgFileList:
      folderName*: string
      folderId*: string
      folderEncrypted*: bool
      folderAppendOnly*: bool
      ownerMachine*: string
      ownerTakeover*: bool
      files*: seq[FileEntry]
    of msgFileRequest:
      requestPath*: string
      requestOffset*: int64
      requestLength*: int
    of msgFileData:
      data*: seq[byte]
      dataOffset*: int64
      totalSize*: int64
      done*: bool
      dataCompression*: CompressionKind
      dataOriginalLen*: int
    of msgFileAck:
      success*: bool
      bytesReceived*: int64
    of msgFileDelete:
      deletedPath*: string
    of msgMoveFile:
      oldPath*: string
      newPath*: string
      moveHash*: string
    of msgListPathsRequest:
      listFolderId*: string
    of msgListPathsResponse:
      listResponseFolderId*: string
      listFiles*: seq[FileEntry]
    of msgPing:
      timestamp*: int64
    of msgPong:
      pingTimestamp*: int64
    of msgSyncDone:
      syncFolderName*: string
    of msgSessionEnd:
      discard
    of msgFolderRefused:
      refusedFolderId*: string
      refusedReason*: string
    of msgRehash:
      rehashPath*: string
      rehashHash*: string
  
  FileEntry* = object
    path*: string
    encryptedPath*: string
    size*: int64
    mtime*: int64
    hash*: string
    mode*: int
    symlinkTarget*: string

const
  ProtocolVersion*: uint8 = 7
  MaxMessageSize*: int = 1024 * 1024 * 30  # 30MB max
  ChunkSize*: int = 64 * 1024  # 64KB chunks

proc encodeInt*[T: SomeInteger](val: T): seq[byte] =
  when T is int64:
    result = @[
      byte(val shr 56),
      byte(val shr 48),
      byte(val shr 40),
      byte(val shr 32),
      byte(val shr 24),
      byte(val shr 16),
      byte(val shr 8),
      byte(val)
    ]
  elif T is int32 or T is uint32:
    result = @[
      byte(val shr 24),
      byte(val shr 16),
      byte(val shr 8),
      byte(val)
    ]
  else:
    result = @[byte(val)]

proc readInt64*(data: seq[byte], offset: int): int64 =
  result = int64(data[offset]) shl 56 or
           int64(data[offset+1]) shl 48 or
           int64(data[offset+2]) shl 40 or
           int64(data[offset+3]) shl 32 or
           int64(data[offset+4]) shl 24 or
           int64(data[offset+5]) shl 16 or
           int64(data[offset+6]) shl 8 or
           int64(data[offset+7])

proc readUint32*(data: seq[byte], offset: int): uint32 =
  result = uint32(data[offset]) shl 24 or
           uint32(data[offset+1]) shl 16 or
           uint32(data[offset+2]) shl 8 or
           uint32(data[offset+3])

proc addString(result: var seq[byte], value: string) =
  result.add(value.len.uint32.encodeInt())
  if value.len > 0:
    result.add(value.toOpenArrayByte(0, value.len - 1))

proc readString(data: seq[byte], pos: var int): Result[string, string] =
  if pos + 4 > data.len:
    return err("Message truncated at pos " & $pos & ", need 4 bytes")

  let length = readUint32(data, pos).int
  pos += 4

  if pos + length > data.len:
    return err("Message truncated at pos " & $pos & ", need " & $length & " bytes")

  var value = newString(length)
  for i in 0..<length:
    value[i] = char(data[pos + i])
  pos += length
  result = ok(value)

proc encode*(msg: ProtocolMessage): seq[byte] =
  result = @[]
  result.add(byte(msg.kind))
  result.add(ProtocolVersion)
  
  case msg.kind
  of msgFileList:
    result.addString(msg.folderName)
    result.addString(msg.folderId)
    result.add(msg.folderEncrypted.byte)
    result.add(msg.folderAppendOnly.byte)
    result.addString(msg.ownerMachine)
    result.add(msg.ownerTakeover.byte)
    result.add(msg.files.len.uint32.encodeInt())
    for f in msg.files:
      result.addString(f.path)
      result.addString(f.encryptedPath)
      result.add(f.size.encodeInt())
      result.add(f.mtime.encodeInt())
      result.addString(f.hash)
      result.add(f.mode.int32.encodeInt())
      result.addString(f.symlinkTarget)

  of msgFileRequest:
    result.addString(msg.requestPath)
    result.add(msg.requestOffset.encodeInt())
    result.add(msg.requestLength.int32.encodeInt())
  
  of msgFileData:
    result.add(msg.dataOffset.encodeInt())
    result.add(msg.totalSize.encodeInt())
    result.add(msg.done.byte)
    result.add(byte(msg.dataCompression))
    result.add(msg.dataOriginalLen.uint32.encodeInt())
    result.add(msg.data.len.uint32.encodeInt())
    result.add(msg.data)
  
  of msgFileAck:
    result.add(msg.success.byte)
    result.add(msg.bytesReceived.encodeInt())
  
  of msgFileDelete:
    result.addString(msg.deletedPath)

  of msgMoveFile:
    result.addString(msg.oldPath)
    result.addString(msg.newPath)
    result.addString(msg.moveHash)

  of msgListPathsRequest:
    result.addString(msg.listFolderId)

  of msgListPathsResponse:
    result.addString(msg.listResponseFolderId)
    result.add(msg.listFiles.len.uint32.encodeInt())
    for f in msg.listFiles:
      result.addString(f.path)
      result.addString(f.encryptedPath)
      result.add(f.size.encodeInt())
      result.add(f.mtime.encodeInt())
      result.addString(f.hash)
      result.add(f.mode.int32.encodeInt())
      result.addString(f.symlinkTarget)

  of msgPing:
    result.add(msg.timestamp.encodeInt())
  
  of msgPong:
    result.add(msg.pingTimestamp.encodeInt())

  of msgSyncDone:
    discard

  of msgSessionEnd:
    discard

  of msgFolderRefused:
    result.addString(msg.refusedFolderId)
    result.addString(msg.refusedReason)

  of msgRehash:
    result.addString(msg.rehashPath)
    result.addString(msg.rehashHash)

proc decode*(data: seq[byte]): Result[ProtocolMessage, string] =
  if data.len < 2:
    return err("Message too short")
  
  let kindByte = data[0]
  if kindByte > ord(high(MessageKind)):
    return err("Invalid message kind: " & $kindByte)
  
  let kind = MessageKind(kindByte)
  let version = data[1]
  
  if version != ProtocolVersion:
    return err("Unsupported protocol version")
  
  var msg = ProtocolMessage(kind: kind)
  
  var pos = 2
  
  template checkLen(n: int) =
    if pos + n > data.len:
      return err("Message truncated at pos " & $pos & ", need " & $n & " bytes")
  
  case kind
  of msgFileList:
    let folderNameRes = readString(data, pos)
    if folderNameRes.isErr:
      return err(folderNameRes.error)
    msg.folderName = folderNameRes.get()

    let folderIdRes = readString(data, pos)
    if folderIdRes.isErr:
      return err(folderIdRes.error)
    msg.folderId = folderIdRes.get()

    checkLen(2)
    msg.folderEncrypted = data[pos] != 0
    msg.folderAppendOnly = data[pos + 1] != 0
    pos += 2

    let ownerMachineRes = readString(data, pos)
    if ownerMachineRes.isErr:
      return err(ownerMachineRes.error)
    msg.ownerMachine = ownerMachineRes.get()
    checkLen(1)
    msg.ownerTakeover = data[pos] != 0
    pos += 1

    checkLen(4)
    let fileCount = readUint32(data, pos).int
    pos += 4
    
    msg.files = @[]
    for i in 0..<fileCount:
      let pathRes = readString(data, pos)
      if pathRes.isErr:
        return err(pathRes.error)
      let path = pathRes.get()

      let encryptedPathRes = readString(data, pos)
      if encryptedPathRes.isErr:
        return err(encryptedPathRes.error)
      let encryptedPath = encryptedPathRes.get()
      
      checkLen(16)
      let size = readInt64(data, pos)
      pos += 8
      let mtime = readInt64(data, pos)
      pos += 8

      let hashRes = readString(data, pos)
      if hashRes.isErr:
        return err(hashRes.error)
      let hash = hashRes.get()

      checkLen(4)
      let mode = cast[int32](readUint32(data, pos)).int
      pos += 4

      let symlinkTargetRes = readString(data, pos)
      if symlinkTargetRes.isErr:
        return err(symlinkTargetRes.error)
      let symlinkTarget = symlinkTargetRes.get()

      msg.files.add(FileEntry(
        path: path,
        encryptedPath: encryptedPath,
        size: size,
        mtime: mtime,
        hash: hash,
        mode: mode,
        symlinkTarget: symlinkTarget,
      ))

  of msgFileRequest:
    let requestPathRes = readString(data, pos)
    if requestPathRes.isErr:
      return err(requestPathRes.error)
    msg.requestPath = requestPathRes.get()
    
    checkLen(12)
    msg.requestOffset = readInt64(data, pos)
    pos += 8
    msg.requestLength = cast[int32](readUint32(data, pos)).int
    pos += 4
  
  of msgFileData:
    checkLen(22)
    msg.dataOffset = readInt64(data, pos)
    pos += 8
    msg.totalSize = readInt64(data, pos)
    pos += 8
    msg.done = data[pos] != 0
    pos += 1
    if data[pos] > ord(ckLz4):
      return err("Invalid compression kind")
    msg.dataCompression = CompressionKind(data[pos])
    pos += 1
    msg.dataOriginalLen = int(readUint32(data, pos))
    pos += 4
    
    checkLen(4)
    let dataLen = readUint32(data, pos).int
    pos += 4
    
    checkLen(dataLen)
    msg.data = data[pos..<pos+dataLen]
  
  of msgFileAck:
    checkLen(9)
    msg.success = data[pos] != 0
    pos += 1
    msg.bytesReceived = readInt64(data, pos)
  
  of msgFileDelete:
    let deletedPathRes = readString(data, pos)
    if deletedPathRes.isErr:
      return err(deletedPathRes.error)
    msg.deletedPath = deletedPathRes.get()

  of msgMoveFile:
    let oldPathRes = readString(data, pos)
    if oldPathRes.isErr:
      return err(oldPathRes.error)
    msg.oldPath = oldPathRes.get()

    let newPathRes = readString(data, pos)
    if newPathRes.isErr:
      return err(newPathRes.error)
    msg.newPath = newPathRes.get()

    let moveHashRes = readString(data, pos)
    if moveHashRes.isErr:
      return err(moveHashRes.error)
    msg.moveHash = moveHashRes.get()

  of msgListPathsRequest:
    let listFolderIdRes = readString(data, pos)
    if listFolderIdRes.isErr:
      return err(listFolderIdRes.error)
    msg.listFolderId = listFolderIdRes.get()

  of msgListPathsResponse:
    let listResponseFolderIdRes = readString(data, pos)
    if listResponseFolderIdRes.isErr:
      return err(listResponseFolderIdRes.error)
    msg.listResponseFolderId = listResponseFolderIdRes.get()

    checkLen(4)
    let fileCount = readUint32(data, pos).int
    pos += 4

    msg.listFiles = @[]
    for i in 0..<fileCount:
      let pathRes = readString(data, pos)
      if pathRes.isErr:
        return err(pathRes.error)

      let encryptedPathRes = readString(data, pos)
      if encryptedPathRes.isErr:
        return err(encryptedPathRes.error)

      checkLen(16)
      let size = readInt64(data, pos)
      pos += 8
      let mtime = readInt64(data, pos)
      pos += 8

      let hashRes = readString(data, pos)
      if hashRes.isErr:
        return err(hashRes.error)

      checkLen(4)
      let mode = cast[int32](readUint32(data, pos)).int
      pos += 4

      let symlinkTargetRes = readString(data, pos)
      if symlinkTargetRes.isErr:
        return err(symlinkTargetRes.error)

      msg.listFiles.add(FileEntry(
        path: pathRes.get(),
        encryptedPath: encryptedPathRes.get(),
        size: size,
        mtime: mtime,
        hash: hashRes.get(),
        mode: mode,
        symlinkTarget: symlinkTargetRes.get(),
      ))

  of msgPing:
    checkLen(8)
    msg.timestamp = readInt64(data, pos)
  
  of msgPong:
    checkLen(8)
    msg.pingTimestamp = readInt64(data, pos)

  of msgSyncDone:
    discard

  of msgSessionEnd:
    discard

  of msgFolderRefused:
    let refusedFolderIdRes = readString(data, pos)
    if refusedFolderIdRes.isErr:
      return err(refusedFolderIdRes.error)
    msg.refusedFolderId = refusedFolderIdRes.get()
    let refusedReasonRes = readString(data, pos)
    if refusedReasonRes.isErr:
      return err(refusedReasonRes.error)
    msg.refusedReason = refusedReasonRes.get()

  of msgRehash:
    let rehashPathRes = readString(data, pos)
    if rehashPathRes.isErr:
      return err(rehashPathRes.error)
    msg.rehashPath = rehashPathRes.get()
    let rehashHashRes = readString(data, pos)
    if rehashHashRes.isErr:
      return err(rehashHashRes.error)
    msg.rehashHash = rehashHashRes.get()
  
  ok(msg)

proc newFileList*(
    folderName: string,
    files: seq[FileEntry],
    folderId = "",
    encrypted = false,
    appendOnly = false,
    ownerMachine = "",
    takeover = false,
): ProtocolMessage =
  ProtocolMessage(
    kind: msgFileList,
    folderName: folderName,
    folderId: folderId,
    folderEncrypted: encrypted,
    folderAppendOnly: appendOnly,
    ownerMachine: ownerMachine,
    ownerTakeover: takeover,
    files: files,
  )

proc newFileRequest*(path: string, offset: int64 = 0, length: int = -1): ProtocolMessage =
  ProtocolMessage(kind: msgFileRequest, requestPath: path, requestOffset: offset, requestLength: length)

proc newFileData*(
    data: seq[byte],
    offset: int64,
    totalSize: int64,
    done: bool = false,
    compression: CompressionKind = ckNone,
    originalLen: int = -1,
): ProtocolMessage =
  ProtocolMessage(
    kind: msgFileData,
    data: data,
    dataOffset: offset,
    totalSize: totalSize,
    done: done,
    dataCompression: compression,
    dataOriginalLen: if originalLen >= 0: originalLen else: data.len
  )

proc newFileAck*(success: bool, bytesReceived: int64 = 0): ProtocolMessage =
  ProtocolMessage(kind: msgFileAck, success: success, bytesReceived: bytesReceived)

proc newFileDelete*(path: string): ProtocolMessage =
  ProtocolMessage(kind: msgFileDelete, deletedPath: path)

proc newMoveFile*(oldPath: string, newPath: string, hash: string): ProtocolMessage =
  ProtocolMessage(kind: msgMoveFile, oldPath: oldPath, newPath: newPath, moveHash: hash)

proc newListPathsRequest*(folderId: string): ProtocolMessage =
  ProtocolMessage(kind: msgListPathsRequest, listFolderId: folderId)

proc newListPathsResponse*(folderId: string, files: seq[FileEntry]): ProtocolMessage =
  ProtocolMessage(kind: msgListPathsResponse, listResponseFolderId: folderId, listFiles: files)

proc newPing*(): ProtocolMessage =
  ProtocolMessage(kind: msgPing, timestamp: getTime().toUnix())

proc newPong*(pingTimestamp: int64): ProtocolMessage =
  ProtocolMessage(kind: msgPong, pingTimestamp: pingTimestamp)

proc newSyncDone*(): ProtocolMessage =
  ProtocolMessage(kind: msgSyncDone)

proc newSessionEnd*(): ProtocolMessage =
  ## Final marker of a sync session. Receiving it proves the buddy has finished
  ## every phase, so closing the connection can no longer cut off data they
  ## still need. Appended to MessageKind so existing kind bytes keep their
  ## values.
  ProtocolMessage(kind: msgSessionEnd)

proc newFolderRefused*(folderId: string, reason: string): ProtocolMessage =
  ## The storage side will not take this folder from us in this session; both
  ## sides skip it, so nothing is changed on either.
  ProtocolMessage(kind: msgFolderRefused, refusedFolderId: folderId, refusedReason: reason)

proc newRehash*(path: string, hash: string): ProtocolMessage =
  ## Replaces the content hash the storage buddy recorded for a file, without
  ## sending the file again.
  ProtocolMessage(kind: msgRehash, rehashPath: path, rehashHash: hash)
