import std/unittest
import std/[json, options]
import libp2p/multiaddress
import chronos
import ../../../src/buddydrive/types
import ../../../src/buddydrive/p2p/node
import ../../support/kv_stub
import ../../support/integration_harness
import ../../../src/buddydrive/p2p/discovery
import ../../../src/buddydrive/recovery
import ../../../src/buddydrive/crypto

suite "Discovery key derivation":
  test "deriveDiscoveryKey produces consistent Base58 output":
    let key1 = deriveDiscoveryKey("swift-eagle", "buddy-a")
    let key2 = deriveDiscoveryKey("swift-eagle", "buddy-a")
    check key1 == key2
    check key1.len > 0

  test "different pairing codes produce different discovery keys":
    let key1 = deriveDiscoveryKey("swift-eagle", "buddy-a")
    let key2 = deriveDiscoveryKey("brave-tiger", "buddy-a")
    check key1 != key2

  test "deriveAuthKey produces consistent 32-byte key":
    let authKey1 = deriveAuthKey("swift-eagle")
    let authKey2 = deriveAuthKey("swift-eagle")
    check authKey1 == authKey2
    check authKey1.len == 32

  test "the two buddies of a pair publish under different keys":
    check deriveDiscoveryKey("swift-eagle", "buddy-a") != deriveDiscoveryKey("swift-eagle", "buddy-b")

  test "different pairing codes produce different auth keys":
    let authKey1 = deriveAuthKey("swift-eagle")
    let authKey2 = deriveAuthKey("brave-tiger")
    check authKey1 != authKey2

  test "discovery key and auth key differ for same pairing code":
    let discoveryKey = deriveDiscoveryKey("swift-eagle", "buddy-a")
    let authKey = deriveAuthKey("swift-eagle")
    check discoveryKey != authKey

suite "Discovery HMAC":
  test "computeHmac produces consistent output":
    let authKey = deriveAuthKey("swift-eagle")
    let hmac1 = computeHmac(authKey, "test data")
    let hmac2 = computeHmac(authKey, "test data")
    check hmac1 == hmac2

  test "different data produces different HMAC":
    let authKey = deriveAuthKey("swift-eagle")
    let hmac1 = computeHmac(authKey, "data one")
    let hmac2 = computeHmac(authKey, "data two")
    check hmac1 != hmac2

  test "different auth keys produce different HMAC for same data":
    let authKey1 = deriveAuthKey("swift-eagle")
    let authKey2 = deriveAuthKey("brave-tiger")
    let hmac1 = computeHmac(authKey1, "test data")
    let hmac2 = computeHmac(authKey2, "test data")
    check hmac1 != hmac2

suite "Deterministic initiator":
  test "non-public side initiates against public buddy":
    let record = BuddyRecord(isPubliclyReachable: true)
    check shouldInitiate("bbbb", false, "aaaa", record)

  test "public side does not initiate against non-public buddy":
    let record = BuddyRecord(isPubliclyReachable: false)
    check not shouldInitiate("aaaa", true, "bbbb", record)

  test "lower uuid initiates when both are public":
    let record = BuddyRecord(isPubliclyReachable: true)
    check shouldInitiate("aaaa", true, "bbbb", record)
    check not shouldInitiate("cccc", true, "bbbb", record)

  test "lower uuid initiates when neither is public":
    let record = BuddyRecord(isPubliclyReachable: false)
    check shouldInitiate("aaaa", false, "bbbb", record)
    check not shouldInitiate("cccc", false, "bbbb", record)

suite "Discovery record":
  test "addresses are published as multiaddr strings":
    let addrs = @[
      MultiAddress.init("/ip4/85.24.176.102/tcp/41721").get(),
      MultiAddress.init("/ip4/192.168.1.101/tcp/41721").get(),
    ]
    let record = parseJson(discoveryRecordJson("peer", addrs, true, "", "eu"))
    check record["addresses"][0].getStr() == "/ip4/85.24.176.102/tcp/41721"
    check record["addresses"][1].getStr() == "/ip4/192.168.1.101/tcp/41721"
    for address in record["addresses"]:
      check MultiAddress.init(address.getStr()).isOk
    check record["relayRegion"].getStr() == "eu"
    check record["isPubliclyReachable"].getBool()

suite "Discovery between two buddies":
  test "each side finds the other's record, not its own":
    discard initCrypto()
    let stub = startKvStub(freePort())
    defer: stub.stop()

    let nodeA = newBuddyNode(0, @[MultiAddress.init("/ip4/203.0.113.1/tcp/41721").get()])
    let nodeB = newBuddyNode(0, @[MultiAddress.init("/ip4/203.0.113.2/tcp/41721").get()])
    waitFor nodeA.start()
    waitFor nodeB.start()
    defer:
      waitFor nodeA.stop()
      waitFor nodeB.stop()

    let a = newDiscovery(nodeA, stub.url, "buddy-a")
    let b = newDiscovery(nodeB, stub.url, "buddy-b")
    waitFor a.start()
    waitFor b.start()

    var buddyOfA, buddyOfB: BuddyInfo
    buddyOfA.id = newBuddyId("buddy-b")
    buddyOfA.pairingCode = "SHAR-EDCD"
    buddyOfB.id = newBuddyId("buddy-a")
    buddyOfB.pairingCode = "SHAR-EDCD"

    check a.publishBuddy(buddyOfA)
    check b.publishBuddy(buddyOfB)

    let seenByA = a.findBuddy("SHAR-EDCD", "buddy-b")
    let seenByB = b.findBuddy("SHAR-EDCD", "buddy-a")
    check seenByA.isSome and seenByA.get().peerId == nodeB.peerIdStr()
    check seenByB.isSome and seenByB.get().peerId == nodeA.peerIdStr()

    # Going offline removes only our own record.
    check a.unpublishBuddy("SHAR-EDCD")
    check b.findBuddy("SHAR-EDCD", "buddy-a").isNone
    check a.findBuddy("SHAR-EDCD", "buddy-b").isSome

  test "a restarted buddy replaces its own record":
    # A restart means a new peer ID, so a new record body and HMAC. The API
    # used to keep the first record forever; the token lets the owner replace it.
    discard initCrypto()
    let stub = startKvStub(freePort())
    defer: stub.stop()

    var buddy: BuddyInfo
    buddy.id = newBuddyId("buddy-b")
    buddy.pairingCode = "SHAR-EDCD"

    let first = newBuddyNode(0, @[MultiAddress.init("/ip4/203.0.113.1/tcp/41721").get()])
    waitFor first.start()
    let firstRun = newDiscovery(first, stub.url, "buddy-a")
    waitFor firstRun.start()
    check firstRun.publishBuddy(buddy)
    waitFor first.stop()

    let second = newBuddyNode(0, @[MultiAddress.init("/ip4/203.0.113.1/tcp/41721").get()])
    waitFor second.start()
    defer: waitFor second.stop()
    let secondRun = newDiscovery(second, stub.url, "buddy-a")
    waitFor secondRun.start()
    check secondRun.publishBuddy(buddy)

    let reader = newDiscovery(second, stub.url, "buddy-b")
    waitFor reader.start()
    let seen = reader.findBuddy("SHAR-EDCD", "buddy-a")
    check seen.isSome and seen.get().peerId == second.peerIdStr()

  test "tokens differ per buddy and per pairing code":
    check discoveryToken("SHAR-EDCD", "buddy-a") == discoveryToken("SHAR-EDCD", "buddy-a")
    check discoveryToken("SHAR-EDCD", "buddy-a") != discoveryToken("SHAR-EDCD", "buddy-b")
    check discoveryToken("SHAR-EDCD", "buddy-a") != discoveryToken("OTHE-RCOD", "buddy-a")
