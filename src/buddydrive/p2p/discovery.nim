import std/[json, options]
import results
import chronos
import curly
import webby/httpheaders
import libsodium/sodium
import libp2p/multiaddress
import ../types
import ../recovery
import node

export results

proc toHex(data: string): string =
  const hexChars = "0123456789abcdef"
  result = newString(data.len * 2)
  for i, ch in data:
    let b = byte(ch)
    result[i * 2] = hexChars[int(b shr 4)]
    result[i * 2 + 1] = hexChars[int(b and 0x0f)]

type
  DiscoveryError* = object of CatchableError

  DiscoveryService* = ref object
    node*: BuddyNode
    apiBaseUrl*: string
    selfId*: string
    started*: bool

  BuddyRecord* = object
    peerId*: string
    addresses*: seq[string]
    relayRegion*: string
    isPubliclyReachable*: bool
    syncTime*: string
    timestamp*: string

const
  DiscoveryKeyContext = "/discovery"
  AuthKeyContext = "/auth"
  PublishInterval* = chronos.seconds(4 * 60 * 60)

proc deriveDiscoveryKey*(pairingCode: string, ownerId: string): string =
  ## Where one side of a pair publishes its record. Both buddies hold the same
  ## pairing code, so the owner's id is part of the key: each side publishes
  ## under its own id and looks the other up under theirs, instead of both
  ## writing, and reading back, a single record.
  let hash = crypto_generichash(pairingCode & "/" & ownerId & DiscoveryKeyContext, 32)
  var hashBytes = newSeq[byte](hash.len)
  for i in 0 ..< hash.len:
    hashBytes[i] = byte(hash[i])
  base58Encode(hashBytes)

proc deriveAuthKey*(pairingCode: string): string =
  let hash = crypto_generichash(pairingCode & AuthKeyContext, 32)
  var authKey = newString(hash.len)
  for i in 0 ..< hash.len:
    authKey[i] = hash[i]
  authKey

proc discoveryToken*(pairingCode: string, ownerId: string): string =
  ## Proves to the API that a write comes from the record's owner. Unlike the
  ## HMAC it does not depend on the record, so a restarted buddy (new peer ID)
  ## can still replace and delete its own record. It includes the owner's id so
  ## one buddy of a pair cannot overwrite the other's record.
  let hash = crypto_generichash(deriveAuthKey(pairingCode) & "/token/" & ownerId, 32)
  var raw = newString(hash.len)
  for i in 0 ..< hash.len:
    raw[i] = char(hash[i])
  toHex(raw)

proc computeHmac*(authKey: string, data: string): string =
  let mac = crypto_auth(data, authKey)
  toHex(mac)

proc discoveryRecordJson*(
    peerId: string,
    addrs: seq[MultiAddress],
    isPubliclyReachable: bool,
    syncTime: string,
    relayRegion: string,
): string =
  var addrStrs: seq[string] = @[]
  for ma in addrs:
    addrStrs.add($ma)

  var j = %*{
    "peerId": peerId,
    "addresses": addrStrs,
    "isPubliclyReachable": isPubliclyReachable,
    "syncTime": syncTime
  }
  if relayRegion.len > 0:
    j["relayRegion"] = %relayRegion
  $j

proc newDiscovery*(node: BuddyNode, apiBaseUrl: string, selfId: string): DiscoveryService =
  result = DiscoveryService()
  result.node = node
  result.apiBaseUrl = apiBaseUrl
  result.selfId = selfId
  result.started = false

proc shouldInitiate*(myBuddyId: string, myPubliclyReachable: bool, buddyId: string, buddyRecord: BuddyRecord): bool =
  if myPubliclyReachable != buddyRecord.isPubliclyReachable:
    return not myPubliclyReachable
  myBuddyId < buddyId

proc start*(discovery: DiscoveryService) {.async.} =
  if discovery.started:
    return
  discovery.started = true

proc stop*(discovery: DiscoveryService) {.async.} =
  discovery.started = false

proc publishBuddy*(discovery: DiscoveryService, buddy: BuddyInfo, relayRegion: string = "", isPubliclyReachable = false): bool =
  if not discovery.started:
    return false

  if buddy.pairingCode.len == 0:
    return false

  let discoveryKey = try: deriveDiscoveryKey(buddy.pairingCode, discovery.selfId) except: return false
  let authKey = try: deriveAuthKey(buddy.pairingCode) except: return false

  let recordJson = discoveryRecordJson(
    discovery.node.peerIdStr(),
    discovery.node.getAdvertisedAddrs(),
    isPubliclyReachable,
    buddy.syncTime,
    relayRegion,
  )
  let hmacHex = try: computeHmac(authKey, recordJson) except: return false
  let token = try: discoveryToken(buddy.pairingCode, discovery.selfId) except: return false

  let url = discovery.apiBaseUrl & "/discovery/" & discoveryKey

  try:
    let curl = newCurly()
    let resp = block:
      var h = emptyHttpHeaders()
      h["Content-Type"] = "application/json"
      h["X-HMAC"] = hmacHex
      h["X-BD-Discovery-Token"] = token
      curl.put(url, h, body = recordJson.toOpenArray(0, recordJson.len - 1), timeout = 30)
    if resp.code == 201:
      return true
    return false
  except Exception as e:
    echo "Error publishing discovery: ", e.msg
    return false

proc unpublishBuddy*(discovery: DiscoveryService, pairingCode: string): bool =
  let discoveryKey = try: deriveDiscoveryKey(pairingCode, discovery.selfId) except: return false
  let authKey = try: deriveAuthKey(pairingCode) except: return false
  let hmacHex = try: computeHmac(authKey, "") except: return false
  let token = try: discoveryToken(pairingCode, discovery.selfId) except: return false

  let url = discovery.apiBaseUrl & "/discovery/" & discoveryKey

  try:
    let curl = newCurly()
    let resp = block:
      var h = emptyHttpHeaders()
      h["X-HMAC"] = hmacHex
      h["X-BD-Discovery-Token"] = token
      curl.delete(url, h, timeout = 30)
    return resp.code == 204
  except Exception as e:
    echo "Error unpublishing discovery: ", e.msg
    return false

proc findBuddy*(discovery: DiscoveryService, pairingCode: string, buddyId: string): Option[BuddyRecord] =
  if not discovery.started:
    return none(BuddyRecord)

  let discoveryKey = try: deriveDiscoveryKey(pairingCode, buddyId) except: return none(BuddyRecord)
  let url = discovery.apiBaseUrl & "/discovery/" & discoveryKey

  try:
    let curl = newCurly()
    let resp = curl.get(url, emptyHttpHeaders(), timeout = 30)
    if resp.code == 200:
      let j = parseJson(resp.body)
      var record = BuddyRecord()
      record.peerId = j["peerId"].getStr()
      record.addresses = @[]
      for addr in j["addresses"]:
        record.addresses.add(addr.getStr())
      if j.hasKey("relayRegion"):
        record.relayRegion = j["relayRegion"].getStr()
      if j.hasKey("isPubliclyReachable"):
        record.isPubliclyReachable = j["isPubliclyReachable"].getBool(false)
      if j.hasKey("syncTime"):
        record.syncTime = j["syncTime"].getStr("")
      if j.hasKey("timestamp"):
        record.timestamp = j["timestamp"].getStr()
      return some(record)
    return none(BuddyRecord)
  except Exception as e:
    echo "Error finding buddy: ", e.msg
    return none(BuddyRecord)

proc publishBuddyLoop*(discovery: DiscoveryService, buddy: BuddyInfo, relayRegion: string = "", isPubliclyReachable = false) {.async.} =
  while discovery.started:
    discard discovery.publishBuddy(buddy, relayRegion, isPubliclyReachable)
    await sleepAsync(PublishInterval)
