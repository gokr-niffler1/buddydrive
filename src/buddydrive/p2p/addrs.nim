import std/strutils
import libp2p/multiaddress

proc isRelayAddress*(ma: MultiAddress): bool =
  ($ma).contains("/p2p-circuit")

proc isLoopbackOrLinkLocal*(ma: MultiAddress): bool =
  let s = $ma
  s.startsWith("/ip4/127.") or s.startsWith("/ip4/169.254.") or
    s.startsWith("/ip6/::1") or s.startsWith("/ip6/fe80")

proc ip4Octets(ma: MultiAddress): seq[int] =
  let parts = ($ma).split("/")
  if parts.len < 3 or parts[1] != "ip4":
    return @[]
  for octet in parts[2].split("."):
    try:
      result.add(parseInt(octet))
    except ValueError:
      return @[]
  if result.len != 4:
    return @[]

proc isPrivateOrLoopback*(ma: MultiAddress): bool =
  let s = $ma
  if isRelayAddress(ma) or isLoopbackOrLinkLocal(ma):
    return true
  if s.startsWith("/ip6/fc") or s.startsWith("/ip6/fd"):
    return true
  let o = ip4Octets(ma)
  if o.len == 4:
    if o[0] == 10 or (o[0] == 192 and o[1] == 168):
      return true
    if o[0] == 172 and o[1] >= 16 and o[1] <= 31:
      return true
    if o[0] == 100 and o[1] >= 64 and o[1] <= 127:
      return true
  false

proc lanHosts*(addrs: seq[MultiAddress]): seq[string] =
  ## The private IPv4 addresses among ours, for telling the user where the
  ## web GUI is reachable on their network.
  for ma in addrs:
    if isRelayAddress(ma) or isLoopbackOrLinkLocal(ma) or not isPrivateOrLoopback(ma):
      continue
    let o = ip4Octets(ma)
    if o.len == 4:
      let host = o.join(".")
      if host notin result:
        result.add(host)

proc isTcp(ma: MultiAddress): bool =
  ($ma).contains("/tcp/")

proc directDialableAddrs*(addrs: seq[MultiAddress]): seq[MultiAddress] =
  ## Public TCP addresses, reachable from anywhere.
  for ma in addrs:
    if isTcp(ma) and not isPrivateOrLoopback(ma):
      result.add(ma)

proc lanDialableAddrs*(addrs: seq[MultiAddress], localAddrs: seq[MultiAddress]): seq[MultiAddress] =
  ## Private TCP addresses of a buddy that sit in the same /24 as one of ours,
  ## so a buddy on the same network is dialed directly instead of through the
  ## router, which often cannot loop a connection back to its own public IP.
  var localNets: seq[seq[int]] = @[]
  for local in localAddrs:
    let o = ip4Octets(local)
    if o.len == 4 and isPrivateOrLoopback(local) and not isLoopbackOrLinkLocal(local):
      localNets.add(o[0 .. 2])
  for ma in addrs:
    if not isTcp(ma) or isRelayAddress(ma) or isLoopbackOrLinkLocal(ma):
      continue
    let o = ip4Octets(ma)
    if o.len == 4 and isPrivateOrLoopback(ma) and o[0 .. 2] in localNets:
      result.add(ma)

proc publishableAddrs*(announceAddrs: seq[MultiAddress], listenAddrs: seq[MultiAddress]): seq[MultiAddress] =
  ## What goes into the discovery record: announced addresses as configured,
  ## then any public address we listen on. Private listen addresses stay out
  ## of the record; a buddy on the same network is given them in its config.
  for ma in announceAddrs:
    if ma notin result:
      result.add(ma)
  for ma in listenAddrs:
    if not isPrivateOrLoopback(ma) and ma notin result:
      result.add(ma)

proc parseAddrs*(values: seq[string]): seq[MultiAddress] =
  for value in values:
    let parsed = MultiAddress.init(value)
    if parsed.isOk and parsed.get() notin result:
      result.add(parsed.get())
