import std/times
import results
import chronos
import libp2p
import libp2p/builders
import libp2p/switch
import libp2p/peerid
import libp2p/peerinfo
import libp2p/multiaddress
import libp2p/crypto/crypto
import libp2p/nameresolving/dnsresolver
import synchandler
import addrs
import ../types

export results

type
  BuddyNodeError* = object of CatchableError
  
  BuddyNode* = ref object
    peerId*: PeerID
    peerInfo*: peerinfo.PeerInfo
    switch*: Switch
    privKey*: PrivateKey
    pubKey*: PublicKey
    listenPort*: int
    announceAddrs*: seq[MultiAddress]
    started*: bool
    startTime*: Time

const BuddyDriveProtocol* = "/buddydrive/2.0.0"

proc generateKeyPair*(): (PublicKey, PrivateKey) =
  var rng = newRng()
  let privKey = PrivateKey.random(PKScheme.Secp256k1, rng[]).tryGet()
  let pubKey = privKey.getPublicKey().tryGet()
  result = (pubKey, privKey)

proc newBuddyNode*(
    privKey: PrivateKey,
    listenPort: int = DefaultP2PPort,
    announceAddrs: seq[MultiAddress] = @[]
): BuddyNode =
  result = BuddyNode()
  result.started = false
  
  result.pubKey = privKey.getPublicKey().tryGet()
  result.privKey = privKey
  result.listenPort = listenPort
  result.announceAddrs = announceAddrs
  
  let peerId = PeerID.init(result.pubKey).tryGet()
  result.peerId = peerId
  result.peerInfo = PeerInfo.new(privKey)

proc newBuddyNode*(): BuddyNode =
  let (_, privKey) = generateKeyPair()
  result = newBuddyNode(privKey)

proc newBuddyNode*(listenPort: int, announceAddrs: seq[MultiAddress] = @[]): BuddyNode =
  let (_, privKey) = generateKeyPair()
  result = newBuddyNode(privKey, listenPort, announceAddrs)

proc start*(node: BuddyNode): Future[void] {.async.} =
  if node.started:
    return

  var listenAddrs: seq[MultiAddress] = @[]
  try:
    listenAddrs.add(MultiAddress.init("/ip4/0.0.0.0/tcp/" & $node.listenPort).tryGet())
  except:
    discard

  let switch = SwitchBuilder.new()
    .withRng(newRng())
    .withPrivateKey(node.privKey)
    .withAddresses(listenAddrs)
    .withNoise()
    .withYamux()
    .withTcpTransport()
    .withNameResolver(DnsResolver.new(@[initTAddress("8.8.8.8", 53.Port), initTAddress("1.1.1.1", 53.Port)]))
    .build()

  let syncHandler = newSyncHandler()
  switch.mount(syncHandler)

  await switch.start()

  node.switch = switch
  node.peerInfo = switch.peerInfo
  node.peerId = switch.peerInfo.peerId

  node.started = true
  node.startTime = getTime()

proc stop*(node: BuddyNode): Future[void] {.async.} =
  if not node.started:
    return
  
  await node.switch.stop()
  node.started = false

proc getAddrs*(node: BuddyNode): seq[MultiAddress] =
  if not node.started:
    return @[]
  result = node.peerInfo.addrs

proc getAdvertisedAddrs*(node: BuddyNode): seq[MultiAddress] =
  publishableAddrs(node.announceAddrs, node.getAddrs())

proc peerIdStr*(node: BuddyNode): string =
  $node.peerId

proc isRunning*(node: BuddyNode): bool =
  node.started
