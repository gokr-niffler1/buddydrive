import std/unittest
import libp2p/multiaddress
import ../../../src/buddydrive/p2p/addrs

proc ma(s: string): MultiAddress =
  MultiAddress.init(s).get()

suite "LAN dialing":
  test "a buddy on our /24 is dialed on its LAN address":
    let remote = @[ma("/ip4/85.24.176.102/tcp/41721"), ma("/ip4/192.168.1.101/tcp/41721")]
    let local = @[ma("/ip4/127.0.0.1/tcp/41721"), ma("/ip4/192.168.1.50/tcp/41721")]
    check lanDialableAddrs(remote, local) == @[ma("/ip4/192.168.1.101/tcp/41721")]

  test "private addresses on another network are not dialed":
    let remote = @[ma("/ip4/192.168.2.101/tcp/41721"), ma("/ip4/10.0.0.5/tcp/41721")]
    let local = @[ma("/ip4/192.168.1.50/tcp/41721")]
    check lanDialableAddrs(remote, local).len == 0

  test "loopback never counts as a shared network":
    let remote = @[ma("/ip4/127.0.0.1/tcp/41721")]
    let local = @[ma("/ip4/127.0.0.1/tcp/41721")]
    check lanDialableAddrs(remote, local).len == 0

  test "public addresses stay the internet route":
    let remote = @[ma("/ip4/85.24.176.102/tcp/41721"), ma("/ip4/192.168.1.101/tcp/41721")]
    check directDialableAddrs(remote) == @[ma("/ip4/85.24.176.102/tcp/41721")]

suite "Published addresses":
  test "private listen addresses are not published":
    let announce = @[ma("/ip4/85.24.176.102/tcp/41721")]
    let listen = @[
      ma("/ip4/127.0.0.1/tcp/41721"),
      ma("/ip4/192.168.1.101/tcp/41721"),
      ma("/ip4/203.0.113.7/tcp/41721"),
    ]
    check publishableAddrs(announce, listen) == @[
      ma("/ip4/85.24.176.102/tcp/41721"),
      ma("/ip4/203.0.113.7/tcp/41721"),
    ]

  test "an explicitly announced address is published as given":
    let announce = @[ma("/ip4/192.168.1.101/tcp/41721")]
    check publishableAddrs(announce, @[]) == announce

  test "parseAddrs skips invalid and duplicate entries":
    check parseAddrs(@["/ip4/192.168.1.101/tcp/41721", "garbage", "/ip4/192.168.1.101/tcp/41721"]) ==
      @[ma("/ip4/192.168.1.101/tcp/41721")]

  test "duplicates are dropped":
    let both = @[ma("/ip4/192.168.1.101/tcp/41721")]
    check publishableAddrs(both, both).len == 1

suite "Private address ranges":
  test "classifies common ranges":
    check isPrivateOrLoopback(ma("/ip4/10.1.2.3/tcp/1"))
    check isPrivateOrLoopback(ma("/ip4/172.16.0.1/tcp/1"))
    check not isPrivateOrLoopback(ma("/ip4/172.32.0.1/tcp/1"))
    check isPrivateOrLoopback(ma("/ip4/100.64.0.1/tcp/1"))
    check not isPrivateOrLoopback(ma("/ip4/100.128.0.1/tcp/1"))
    check not isPrivateOrLoopback(ma("/ip4/8.8.8.8/tcp/1"))

suite "LAN hosts":
  test "private IPv4 addresses, without loopback, public or duplicates":
    let addrs = @[
      ma("/ip4/127.0.0.1/tcp/41721"),
      ma("/ip4/192.168.1.223/tcp/41721"),
      ma("/ip4/192.168.1.79/tcp/41721"),
      ma("/ip4/85.24.176.102/tcp/41721"),
      ma("/ip4/192.168.1.223/tcp/41722"),
    ]
    check lanHosts(addrs) == @["192.168.1.223", "192.168.1.79"]

  test "none when only loopback is bound":
    check lanHosts(@[ma("/ip4/127.0.0.1/tcp/41721")]).len == 0
