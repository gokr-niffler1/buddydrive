import std/unittest
import std/options
import chronos
import libp2p/stream/[connection, bufferstream]
import ../../../src/buddydrive/p2p/messages
import ../../../src/buddydrive/types
import ../../../src/buddydrive/p2p/pairing

suite "BuddyConnection state":
  test "newBuddyConnection starts in psNone":
    let bc = newBuddyConnection()
    check bc.state == psNone
    check bc.buddyId == ""
    check bc.buddyName == ""

  test "isConnected is false for psNone":
    let bc = newBuddyConnection()
    check not bc.isConnected()

  test "isConnected is false when conn is nil regardless of state":
    let bc = newBuddyConnection()
    bc.state = psReady
    check not bc.isConnected()

  test "isConnected is false for psError":
    let bc = newBuddyConnection()
    bc.state = psError
    check not bc.isConnected()

  test "isConnected is false for psHandshake":
    let bc = newBuddyConnection()
    bc.state = psHandshake
    check not bc.isConnected()

suite "verifyBuddy":
  test "returns true when buddy UUID matches config":
    let bc = newBuddyConnection()
    bc.buddyId = "buddy-1"
    var config = newAppConfig(newBuddyId("me", "myself"))
    var buddy: BuddyInfo
    buddy.id = newBuddyId("buddy-1", "Alice")
    config.buddies = @[buddy]
    check bc.verifyBuddy(config)
    check bc.buddyName == "Alice"

  test "returns false when buddy UUID not in config":
    let bc = newBuddyConnection()
    bc.buddyId = "unknown-buddy"
    var config = newAppConfig(newBuddyId("me", "myself"))
    var buddy: BuddyInfo
    buddy.id = newBuddyId("buddy-1", "Alice")
    config.buddies = @[buddy]
    check not bc.verifyBuddy(config)

  test "returns false with empty buddies list":
    let bc = newBuddyConnection()
    bc.buddyId = "anyone"
    let config = newAppConfig(newBuddyId("me", "myself"))
    check not bc.verifyBuddy(config)

  test "matches against multiple buddies":
    let bc = newBuddyConnection()
    bc.buddyId = "buddy-2"
    var config = newAppConfig(newBuddyId("me", "myself"))
    var b1: BuddyInfo
    b1.id = newBuddyId("buddy-1", "Alice")
    var b2: BuddyInfo
    b2.id = newBuddyId("buddy-2", "Bob")
    config.buddies = @[b1, b2]
    check bc.verifyBuddy(config)
    check bc.buddyName == "Bob"

suite "handshake failures":
  proc frame(data: seq[byte]): seq[byte] =
    let n = data.len
    result = @[byte(n shr 24), byte(n shr 16), byte(n shr 8), byte(n)] & data

  proc handshakeFrame(version: uint8): seq[byte] =
    var data = encode(ProtocolMessage(kind: msgFileList, folderName: "BUDDYDRIVE_PAIRING",
      files: @[FileEntry(path: "buddy-1", hash: "Alice")]))
    data[1] = version
    frame(data)

  proc receiveFrom(bytes: seq[byte]): (Option[(string, string)], string) =
    let stream = BufferStream.new()
    waitFor stream.pushData(bytes)
    let bc = newBuddyConnection()
    bc.conn = stream
    let received = waitFor bc.receiveBuddyId()
    waitFor stream.close()
    (received, bc.failure)

  test "a handshake on this protocol version is read":
    let (received, failure) = receiveFrom(handshakeFrame(ProtocolVersion))
    check received.isSome
    check received.get() == ("buddy-1", "Alice")
    check failure == ""

  test "another protocol version is named, not taken for a stranger":
    let (received, failure) = receiveFrom(handshakeFrame(ProtocolVersion - 1))
    check received.isNone
    check failure == "it speaks protocol version " & $(ProtocolVersion - 1) &
      ", this build speaks " & $ProtocolVersion & "; update the older side"

  test "an unknown buddy id is named":
    let bc = newBuddyConnection()
    bc.buddyId = "stranger"
    check not bc.verifyBuddy(newAppConfig(newBuddyId("me", "myself")))
    check bc.failure == "buddy id stranger is not in this config"
