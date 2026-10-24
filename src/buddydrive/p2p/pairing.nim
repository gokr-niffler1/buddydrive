import std/times
import results
import chronos
import libp2p
import libp2p/protocols/protocol
import libp2p/stream/connection
import messages
import protocol
import ../types

export results

type
  PairingError* = object of CatchableError
  
  PairingState* = enum
    psNone
    psHandshake
    psExchangingId
    psVerifying
    psReady
    psError
  
  BuddyConnection* = ref object
    buddyId*: string
    buddyName*: string
    peerId*: string
    conn*: Connection
    state*: PairingState
    lastActivity*: Time
    failure*: string
      ## Why the handshake failed, for the log.

const
  PairingProtocol* = "/buddydrive/pairing/2.0.0"
  HandshakeTimeout* = chronos.seconds(30)

proc newBuddyConnection*(): BuddyConnection =
  result = BuddyConnection()
  result.state = psNone
  result.lastActivity = getTime()

proc sendBuddyId*(bc: BuddyConnection, buddyId: string, buddyName: string): Future[void] {.async.} =
  let msg = ProtocolMessage(
    kind: msgFileList,
    folderName: "BUDDYDRIVE_PAIRING",
    files: @[FileEntry(
      path: buddyId,
      size: 0,
      mtime: getTime().toUnix(),
      hash: buddyName
    )]
  )
  await sendFramedMessage(bc.conn, msg)
  bc.lastActivity = getTime()

proc receiveBuddyId*(bc: BuddyConnection): Future[Option[(string, string)]] {.async.} =
  ## Reads the frame itself rather than through receiveFramedMessage, so a
  ## buddy on another protocol version can be told apart from a stranger.
  try:
    var lenBytes: array[4, byte]
    await bc.conn.readExactly(addr lenBytes[0], 4).wait(HandshakeTimeout)
    let msgLen = int(lenBytes[0]) shl 24 or int(lenBytes[1]) shl 16 or
                 int(lenBytes[2]) shl 8 or int(lenBytes[3])
    if msgLen <= 0 or msgLen > MaxMessageSize:
      bc.failure = "not a BuddyDrive handshake"
      return none((string, string))
    var data = newSeq[byte](msgLen)
    await bc.conn.readExactly(addr data[0], msgLen).wait(HandshakeTimeout)

    if data.len >= 2 and data[1] != ProtocolVersion:
      bc.failure = "it speaks protocol version " & $data[1] & ", this build speaks " &
        $ProtocolVersion & "; update the older side"
      return none((string, string))

    let decoded = decode(data)
    if decoded.isErr:
      bc.failure = "unreadable handshake: " & decoded.error
      return none((string, string))
    let msg = decoded.get()
    if msg.kind != msgFileList or msg.folderName != "BUDDYDRIVE_PAIRING" or msg.files.len != 1:
      bc.failure = "not a BuddyDrive handshake"
      return none((string, string))

    let buddyId = msg.files[0].path
    let buddyName = msg.files[0].hash
    bc.buddyId = buddyId
    bc.buddyName = buddyName
    bc.lastActivity = getTime()
    
    return some((buddyId, buddyName))
  except CatchableError as e:
    bc.failure = "no handshake received: " & e.msg
    return none((string, string))

proc verifyBuddy*(bc: BuddyConnection, config: AppConfig): bool =
  for buddy in config.buddies:
    if buddy.id.uuid == bc.buddyId:
      bc.buddyName = buddy.id.name
      return true
  bc.failure = "buddy id " & bc.buddyId & " is not in this config"
  return false

proc performHandshake*(bc: BuddyConnection, config: AppConfig): Future[bool] {.async.} =
  bc.state = psHandshake
  
  try:
    await bc.sendBuddyId(config.buddy.uuid, config.buddy.name)
    
    let buddyInfoOpt = await bc.receiveBuddyId()
    if buddyInfoOpt.isNone:
      bc.state = psError
      return false
    
    let (buddyId, buddyName) = buddyInfoOpt.get()
    bc.buddyId = buddyId
    bc.buddyName = buddyName
    
    bc.state = psVerifying
    
    if not bc.verifyBuddy(config):
      bc.state = psError
      return false
    
    bc.state = psReady
    return true
  except:
    bc.state = psError
    return false

proc acceptHandshake*(bc: BuddyConnection, config: AppConfig): Future[bool] {.async.} =
  bc.state = psHandshake
  
  try:
    let buddyInfoOpt = await bc.receiveBuddyId()
    if buddyInfoOpt.isNone:
      bc.state = psError
      return false
    
    let (buddyId, buddyName) = buddyInfoOpt.get()
    bc.buddyId = buddyId
    bc.buddyName = buddyName
    
    bc.state = psVerifying
    
    if not bc.verifyBuddy(config):
      bc.state = psError
      return false
    
    await bc.sendBuddyId(config.buddy.uuid, config.buddy.name)
    
    bc.state = psReady
    return true
  except:
    bc.state = psError
    return false

proc isConnected*(bc: BuddyConnection): bool =
  bc.state == psReady and bc.conn != nil

proc close*(bc: BuddyConnection) {.async.} =
  if bc.conn != nil:
    try:
      await bc.conn.close()
    except:
      discard
  bc.state = psNone
  bc.conn = nil

proc newPairingHandler*(handlerProc: proc(conn: Connection): Future[void] {.closure, gcsafe, raises: [CancelledError].}): LPProtocol =
  let handler = proc(conn: Connection, proto: string): Future[void] {.closure, gcsafe, async: (raises: [CancelledError]).} =
    try:
      await handlerProc(conn)
    except CancelledError:
      raise
    except CatchableError:
      discard
  LPProtocol.new(@[PairingProtocol], handler)
