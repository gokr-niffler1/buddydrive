import std/times
import std/options
import results
import chronos
import libp2p
import libp2p/stream/connection
import messages

export results

type
  ProtocolError* = object of CatchableError

  SyncProtocol* = ref object

var
  messageIdleTimeout* = chronos.minutes(5)
    ## How long a buddy may stay silent mid-session before we give up on it.
    ## The session runs inside the connection handler, so without a limit a
    ## buddy that stalls would hold the connection forever.
  folderListTimeout* = chronos.minutes(30)
    ## Waiting for the buddy's folder lists covers its scan of every folder;
    ## hashing a large folder for the first time takes a while.

proc newSyncProtocol*(): SyncProtocol =
  result = SyncProtocol()

proc newSyncProtocol*[T](node: T): SyncProtocol =
  discard node
  result = SyncProtocol()

proc sendFramedMessage*(conn: Connection, msg: ProtocolMessage, timeout = messageIdleTimeout): Future[void] {.async.} =
  ## Raises AsyncTimeoutError when the buddy stops reading.
  let encoded = encode(msg)
  var lenBytes: array[4, byte]
  lenBytes[0] = byte(encoded.len shr 24)
  lenBytes[1] = byte(encoded.len shr 16)
  lenBytes[2] = byte(encoded.len shr 8)
  lenBytes[3] = byte(encoded.len)

  await conn.write(@lenBytes).wait(timeout)
  await conn.write(encoded).wait(timeout)

proc receiveFramedMessage*(conn: Connection, timeout = messageIdleTimeout): Future[Option[ProtocolMessage]] {.async.} =
  ## none when the stream ends, the message is unusable, or nothing arrives
  ## within the timeout; the stream is not usable after any of those.
  try:
    var lenBytes: array[4, byte]
    await conn.readExactly(addr lenBytes[0], 4).wait(timeout)

    let msgLen = int(lenBytes[0]) shl 24 or
                 int(lenBytes[1]) shl 16 or
                 int(lenBytes[2]) shl 8 or
                 int(lenBytes[3])

    if msgLen > MaxMessageSize or msgLen <= 0:
      return none(ProtocolMessage)

    var data = newSeq[byte](msgLen)
    await conn.readExactly(addr data[0], msgLen).wait(timeout)

    let decoded = decode(data)
    if decoded.isErr:
      return none(ProtocolMessage)

    return some(decoded.get())
  except:
    return none(ProtocolMessage)

proc sendMessage*(protocol: SyncProtocol, conn: Connection, msg: ProtocolMessage, timeout = messageIdleTimeout): Future[void] {.async.} =
  discard protocol
  await sendFramedMessage(conn, msg, timeout)

proc receiveMessage*(protocol: SyncProtocol, conn: Connection, timeout = messageIdleTimeout): Future[Option[ProtocolMessage]] {.async.} =
  discard protocol
  return await receiveFramedMessage(conn, timeout)

proc sendPing*(protocol: SyncProtocol, conn: Connection): Future[int64] {.async.} =
  let ping = newPing()
  await protocol.sendMessage(conn, ping)
  
  let pongOpt = await protocol.receiveMessage(conn)
  if pongOpt.isNone or pongOpt.get().kind != msgPong:
    raise newException(ProtocolError, "Did not receive pong")
  
  let now = getTime().toUnix()
  result = now - pongOpt.get().pingTimestamp
