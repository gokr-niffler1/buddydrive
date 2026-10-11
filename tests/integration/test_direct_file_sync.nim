import std/[os, sequtils, tables, times, unittest]
import chronos
import libp2p
import ../../src/buddydrive/types
import ../../src/buddydrive/control
import ../../src/buddydrive/daemon
import ../../src/buddydrive/p2p/node
import ../../src/buddydrive/p2p/pairing
import ../../src/buddydrive/p2p/protocol
import ../../src/buddydrive/sync/session
import ../support/integration_harness
import ../support/sync_fixtures
import ../testutils

useIsolatedDataDir("direct_file_sync")

proc dialAndSync(cfg: AppConfig, listener: BuddyNode, port: int): Future[bool] {.async.} =
  let node = newBuddyNode(port)
  await node.start()
  defer: await node.stop()

  let conn = await node.switch.dial(listener.peerId, listener.getAddrs(), PairingProtocol)
  let bc = newBuddyConnection()
  bc.conn = conn
  if not await bc.performHandshake(cfg):
    return false
  result = await syncBuddyFolders(cfg, bc.buddyId, conn, newSyncProtocol())
  await bc.close()

suite "Direct file sync":
  test "a full session runs over an incoming libp2p connection":
    # The daemon's handler for incoming connections used to start the sync in
    # the background and return, and libp2p closes a stream as soon as its
    # handler returns. Relay connections do not go through that handler, so
    # only a real dial shows it.
    withTestDir("direct_sync"):
      let folderA = testDir / "a"
      let folderB = testDir / "b"
      createDir(folderA)
      createDir(folderB)
      writeFile(folderA / "from-a.txt", "a secret\n")
      writeFile(folderB / "from-b.txt", "b secret\n")

      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", folderB)])

      let listener = newDaemon(cfgB)
      listener.node = newBuddyNode(freePort())
      waitFor listener.node.start()
      listener.syncProtocol = newSyncProtocol(listener.node)
      waitFor listener.mountPairingProtocol()
      defer: waitFor listener.node.stop()

      check waitFor dialAndSync(cfgA, listener.node, freePort())

      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 1
      check storedFiles(testDir / "a-stores" / "folder-b", ".blob").len == 1
      check not anyFileMentions(testDir / "b-stores", ["from-a", "a secret"])

proc startedDaemon(cfg: AppConfig): Daemon =
  result = newDaemon(cfg)
  result.node = newBuddyNode(freePort())
  waitFor result.node.start()
  result.syncProtocol = newSyncProtocol(result.node)
  waitFor result.mountPairingProtocol()
  result.running = true

proc dialAndWait(dialer: Daemon, listener: Daemon, buddyId: string): bool =
  if not waitFor dialer.connectToBuddy(buddyId, listener.node.peerId, listener.node.getAddrs()):
    return false
  for _ in 0 ..< 200:
    if not dialer.activeSyncs.getOrDefault(buddyId) and not listener.activeSyncs.getOrDefault(dialer.config.buddy.uuid):
      return true
    waitFor sleepAsync(chronos.milliseconds(50))
  false

suite "Daemon sessions":
  test "a buddy is dialed again after a session, and folder status is kept":
    # A finished session used to leave its connection marked ready, so the
    # discovery loop never dialed that buddy again.
    withTestDir("daemon_redial"):
      let folderA = testDir / "a"
      let folderB = testDir / "b"
      createDir(folderA)
      createDir(folderB)
      writeFile(folderA / "first.txt", "first\n")

      let cfgA = peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA, name = "docs")])
      let cfgB = peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", folderB)])
      let a = startedDaemon(cfgA)
      let b = startedDaemon(cfgB)
      defer:
        waitFor a.node.stop()
        waitFor b.node.stop()

      check dialAndWait(a, b, BuddyTwo)
      check BuddyTwo notin a.buddyConnections
      check BuddyOne notin b.buddyConnections
      let status = a.getFolderStatus()
      check status.len == 1
      check status[0].status == "synced"
      check status[0].lastSync.toUnix() > 0

      writeFile(folderA / "second.txt", "second\n")
      check dialAndWait(a, b, BuddyTwo)
      check storedFiles(testDir / "b-stores" / "folder-a", ".blob").len == 2

      let dialed = a.currentSessions()
      check dialed.len == 2
      check dialed.allIt(it.outcome == "ok" and it.dialedBy == "us" and it.via == "direct")
      check dialed.allIt(it.filesSent == 1 and it.bytesSent > 0 and it.filesReceived == 0)
      check dialed[1].buddyId == BuddyTwo
      let answered = b.currentSessions()
      check answered.len == 2
      check answered.allIt(it.outcome == "ok" and it.dialedBy == "buddy" and it.filesReceived == 1)

  test "a buddy dialing in during a running sync is turned away, and that is recorded":
    withTestDir("daemon_turned_away"):
      let folderA = testDir / "a"
      let folderB = testDir / "b"
      createDir(folderA)
      createDir(folderB)
      let a = startedDaemon(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)]))
      let b = startedDaemon(peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", folderB)]))
      defer:
        waitFor a.node.stop()
        waitFor b.node.stop()

      b.activeSyncs[BuddyOne] = true
      discard dialAndWait(a, b, BuddyTwo)
      let turned = b.currentSessions()
      check turned.len == 1
      check turned[0].outcome == "turned away"
      check turned[0].dialedBy == "buddy"
      check turned[0].buddyId == BuddyOne
      check a.currentSessions()[0].outcome == "failed"

  test "a dial that loses to a running session keeps that session's connection tracked":
    # The losing dial replaced the running session's connection in
    # buddyConnections and then dropped it, so the buddy showed as
    # disconnected while it synced, and was dialed again.
    withTestDir("daemon_dial_race"):
      let folderA = testDir / "a"
      let folderB = testDir / "b"
      createDir(folderA)
      createDir(folderB)
      let a = startedDaemon(peerConfig(BuddyOne, BuddyTwo, testDir / "a-stores", @[syncFolder("folder-a", folderA)]))
      let b = startedDaemon(peerConfig(BuddyTwo, BuddyOne, testDir / "b-stores", @[syncFolder("folder-b", folderB)]))
      defer:
        waitFor a.node.stop()
        waitFor b.node.stop()

      let running = newBuddyConnection()
      a.activeSyncs[BuddyTwo] = true
      a.buddyConnections[BuddyTwo] = running
      check waitFor a.connectToBuddy(BuddyTwo, b.node.peerId, b.node.getAddrs())
      check a.buddyConnections.getOrDefault(BuddyTwo) == running
      check a.currentSessions()[^1].outcome == "turned away"
      for _ in 0 ..< 200:
        if not b.activeSyncs.getOrDefault(BuddyOne):
          break
        waitFor sleepAsync(chronos.milliseconds(50))

  test "a sync asked for from a GUI dials the buddy now":
    withTestDir("daemon_sync_request"):
      let folderA = testDir / "a"
      let folderB = testDir / "b"
      createDir(folderA)
      createDir(folderB)
      writeFile(folderA / "file.txt", "content\n")

      # B would normally be the one to dial (lower UUID initiates), and is
      # outside its sync window: a request from the GUI overrides both.
      var cfgA = peerConfig(BuddyTwo, BuddyOne, testDir / "a-stores", @[syncFolder("folder-a", folderA, name = "docs")])
      cfgA.buddies[0].syncWindow = (now() + 12.hours).format("HH:mm")
      let cfgB = peerConfig(BuddyOne, BuddyTwo, testDir / "b-stores", @[syncFolder("folder-b", folderB)])
      let a = startedDaemon(cfgA)
      let b = startedDaemon(cfgB)
      defer:
        waitFor a.node.stop()
        waitFor b.node.stop()

      writeCachedBuddyAddr(BuddyOne, $b.node.peerId, b.node.getAddrs().mapIt($it), "")
      a.handleSyncRequests(@["docs"])
      var stored = 0
      for _ in 0 ..< 200:
        stored = storedFiles(testDir / "b-stores" / "folder-a", ".blob").len
        if stored > 0 and not a.activeSyncs.getOrDefault(BuddyOne):
          break
        waitFor sleepAsync(chronos.milliseconds(50))
      check stored == 1
      check a.getFolderStatus()[0].status == "synced"
