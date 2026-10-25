import std/unittest
import chronos
import ../../src/buddydrive/types
import ../../src/buddydrive/p2p/rawrelay
import ../../src/buddydrive/p2p/pairing
import ../support/test_relay
import ../testutils

useIsolatedDataDir("relay_fallback")
shortenSessionTimeouts()

proc makeConfig(
    selfId: string,
    selfName: string,
    otherId: string,
    otherName: string,
    pairingCode: string,
): AppConfig =
  result = newAppConfig(newBuddyId(selfId, selfName))
  result.relayRegion = "local"
  result.apiBaseUrl = ""
  var buddy: BuddyInfo
  buddy.id = newBuddyId(otherId, otherName)
  buddy.pairingCode = pairingCode
  result.buddies = @[buddy]

proc connectAndPair(config: AppConfig): Future[string] {.async.} =
  var relayListCache = initRelayListCache()
  let relayConn = await connectViaRegionalRelay(
    relayListCache,
    config.apiBaseUrl,
    config.relayRegion,
    config.buddies[0].pairingCode
  )
  let conn = relayConn.conn
  let bc = newBuddyConnection()
  bc.conn = conn
  let success = await bc.performHandshake(config)
  doAssert success
  let remoteName = bc.buddyName
  await bc.close()
  remoteName

suite "Relay fallback pairing":
  var relay: TestRelay

  setup:
    relay = startTestRelay()

  teardown:
    waitFor relay.stop()

  test "two nodes pair via relay":
    let cfg1 = makeConfig(
      "11111111-1111-1111-1111-111111111111",
      "buddy-one",
      "22222222-2222-2222-2222-222222222222",
      "buddy-two",
      "swift-eagle"
    )
    let cfg2 = makeConfig(
      "22222222-2222-2222-2222-222222222222",
      "buddy-two",
      "11111111-1111-1111-1111-111111111111",
      "buddy-one",
      "swift-eagle"
    )

    let f1 = connectAndPair(cfg1)
    let f2 = connectAndPair(cfg2)
    let r1 = waitFor f1
    let r2 = waitFor f2

    check r1 == "buddy-two"
    check r2 == "buddy-one"

  test "peers with different pairing codes do not meet":
    let cfg1 = makeConfig(
      "11111111-1111-1111-1111-111111111111",
      "buddy-one",
      "22222222-2222-2222-2222-222222222222",
      "buddy-two",
      "swift-eagle"
    )
    let cfg2 = makeConfig(
      "22222222-2222-2222-2222-222222222222",
      "buddy-two",
      "11111111-1111-1111-1111-111111111111",
      "buddy-one",
      "other-code"
    )

    # Both peers stay parked on the relay waiting for a matching token, so the
    # handshake must not complete.
    let paired = waitFor allFutures(connectAndPair(cfg1), connectAndPair(cfg2))
      .withTimeout(chronos.seconds(2))
    check not paired
