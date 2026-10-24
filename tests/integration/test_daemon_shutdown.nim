import std/[httpclient, os, osproc, streams, strtabs, strutils, times, unittest]
import ../../src/buddydrive/types
import ../../src/buddydrive/config as buddyconfig
import ../../src/buddydrive/p2p/discovery
import ../support/integration_harness
import ../support/kv_stub
import ../support/sync_fixtures
import ../testutils

var cliBinaryPath {.global.}: string

const PairingCode = "SHUT-DOWN2"

proc ensureCliBinary(): string =
  ensureBuiltBinary(cliBinaryPath, "buddydrive_test_shutdown", "nim c -o:$OUT src/buddydrive.nim")

proc daemonEnv(dir: string): StringTableRef =
  result = newStringTable()
  for key, value in envPairs():
    result[key] = value
  result["BUDDYDRIVE_CONFIG_DIR"] = dir
  result["BUDDYDRIVE_DATA_DIR"] = dir

proc writeDaemonConfig(dir: string, apiUrl: string) =
  putEnv("BUDDYDRIVE_CONFIG_DIR", dir)
  putEnv("BUDDYDRIVE_DATA_DIR", dir)
  defer:
    delEnv("BUDDYDRIVE_CONFIG_DIR")
    delEnv("BUDDYDRIVE_DATA_DIR")
  var cfg = newAppConfig(newBuddyId(BuddyOne, "shutdown-test"))
  cfg.apiBaseUrl = apiUrl
  cfg.relayRegion = ""
  cfg.listenPort = freePort()
  # An announce address keeps the daemon away from the real router's UPnP.
  cfg.announceAddr = "/ip4/127.0.0.1/tcp/" & $cfg.listenPort
  var buddy: BuddyInfo
  buddy.id = newBuddyId(BuddyTwo, "other")
  buddy.pairingCode = PairingCode
  buddy.addedAt = getTime()
  cfg.buddies = @[buddy]
  buddyconfig.saveConfig(cfg)

proc recordPublished(apiUrl: string): bool =
  let client = newHttpClient()
  defer: client.close()
  let url = apiUrl & "/discovery/" & deriveDiscoveryKey(PairingCode, BuddyOne)
  try:
    client.get(url).code == Http200
  except CatchableError:
    false

proc waitForRecord(apiUrl: string, seconds: int): bool =
  for _ in 0 ..< seconds * 10:
    if recordPublished(apiUrl):
      return true
    sleep(100)
  false

proc startDaemon(dir: string): Process =
  startProcess(
    ensureCliBinary(),
    workingDir = dir,
    args = @["start", "--port", $freePort()],
    env = daemonEnv(dir),
    options = {poStdErrToStdOut}
  )

suite "Daemon shutdown":
  test "SIGTERM stops the daemon cleanly and unpublishes it":
    withTestDir("shutdown_sigterm"):
      let stub = startKvStub(freePort())
      defer: stub.stop()
      writeDaemonConfig(testDir, stub.url)

      let daemon = startDaemon(testDir)
      defer: close(daemon)
      check waitForRecord(stub.url, 30)

      terminate(daemon)
      let exitCode = waitForExit(daemon, 30_000)
      let output = daemon.outputStream.readAll()
      check exitCode == 0
      check "stopping cleanly" in output
      check "Daemon stopped" in output
      check not recordPublished(stub.url)

  test "buddydrive stop asks a running daemon to shut down":
    withTestDir("shutdown_stop_command"):
      let stub = startKvStub(freePort())
      defer: stub.stop()
      writeDaemonConfig(testDir, stub.url)

      let daemon = startDaemon(testDir)
      defer: close(daemon)
      check waitForRecord(stub.url, 30)

      let stop = execCmdEx(quoteShell(ensureCliBinary()) & " stop", env = daemonEnv(testDir), workingDir = testDir)
      check stop.exitCode == 0
      let exitCode = waitForExit(daemon, 30_000)
      check exitCode == 0
      check not recordPublished(stub.url)
