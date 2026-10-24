import std/[os, osproc, strtabs, strutils, unittest]
import ../../src/buddydrive/config as buddyconfig
import ../testutils
import ../support/integration_harness

var cliBinaryPath {.global.}: string

proc ensureCliBinary(): string =
  ensureBuiltBinary(cliBinaryPath, "buddydrive_test_cli", "nim c -o:$OUT src/buddydrive.nim")

proc cliEnv(testDir: string): StringTableRef =
  result = newStringTable()
  result["BUDDYDRIVE_CONFIG_DIR"] = testDir
  result["BUDDYDRIVE_DATA_DIR"] = testDir
  result["HOME"] = testDir

template withCliEnv(testDir: string, body: untyped): untyped =
  putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
  putEnv("BUDDYDRIVE_DATA_DIR", testDir)
  defer:
    delEnv("BUDDYDRIVE_CONFIG_DIR")
    delEnv("BUDDYDRIVE_DATA_DIR")
  body

suite "CLI flows":
  test "init creates config":
    withTestDir("cliinit"):
      let cli = ensureCliBinary()
      let result = execCmdEx(quoteShell(cli) & " init", env = cliEnv(testDir), workingDir = repoRoot())
      check result.exitCode == 0
      check result.output.contains("Config created at")
      check fileExists(testDir / "config.toml")

  test "add-buddy stores pairing code":
    withTestDir("cliaddbuddy"):
      let cli = ensureCliBinary()
      discard execCmdEx(quoteShell(cli) & " init", env = cliEnv(testDir), workingDir = repoRoot())
      let result = execCmdEx(
        quoteShell(cli) & " add-buddy --id buddy-1 --code swift-eagle",
        env = cliEnv(testDir),
        workingDir = repoRoot()
      )
      check result.exitCode == 0
      withCliEnv(testDir):
        let cfg = buddyconfig.loadConfig()
        check cfg.buddies.len == 1
        check cfg.buddies[0].id.uuid == "buddy-1"
        check cfg.buddies[0].pairingCode == "swift-eagle"

  test "pairing leaves both buddies with the same code":
    withTestDir("clipairing"):
      let cli = ensureCliBinary()
      let dirA = testDir / "a"
      let dirB = testDir / "b"
      createDir(dirA)
      createDir(dirB)
      discard execCmdEx(quoteShell(cli) & " init", env = cliEnv(dirA), workingDir = repoRoot())
      discard execCmdEx(quoteShell(cli) & " init", env = cliEnv(dirB), workingDir = repoRoot())
      var idA, idB: string
      withCliEnv(dirA):
        idA = buddyconfig.loadConfig().buddy.uuid
      withCliEnv(dirB):
        idB = buddyconfig.loadConfig().buddy.uuid

      let generated = execCmdEx(
        quoteShell(cli) & " add-buddy --generate-code --id " & idB,
        env = cliEnv(dirA),
        workingDir = repoRoot()
      )
      check generated.exitCode == 0
      var codeA: string
      withCliEnv(dirA):
        let cfgA = buddyconfig.loadConfig()
        check cfgA.buddies.len == 1
        check cfgA.buddies[0].id.uuid == idB
        codeA = cfgA.buddies[0].pairingCode
      check codeA.len == 9
      check generated.output.contains("add-buddy --id " & idA & " --code " & codeA)

      discard execCmdEx(
        quoteShell(cli) & " add-buddy --id " & idA & " --code " & codeA,
        env = cliEnv(dirB),
        workingDir = repoRoot()
      )
      withCliEnv(dirB):
        let cfgB = buddyconfig.loadConfig()
        check cfgB.buddies.len == 1
        check cfgB.buddies[0].id.uuid == idA
        check cfgB.buddies[0].pairingCode == codeA

  test "generate-code without a buddy id saves nothing":
    withTestDir("cligeneratenoid"):
      let cli = ensureCliBinary()
      discard execCmdEx(quoteShell(cli) & " init", env = cliEnv(testDir), workingDir = repoRoot())
      let result = execCmdEx(quoteShell(cli) & " add-buddy --generate-code", env = cliEnv(testDir), workingDir = repoRoot())
      check result.output.contains("Buddy ID required")
      withCliEnv(testDir):
        check buddyconfig.loadConfig().buddies.len == 0

  test "re-pairing keeps the buddy's other settings":
    withTestDir("clirepair"):
      let cli = ensureCliBinary()
      discard execCmdEx(quoteShell(cli) & " init", env = cliEnv(testDir), workingDir = repoRoot())
      discard execCmdEx(quoteShell(cli) & " add-buddy --id buddy-1 --code AAAA-BBBB", env = cliEnv(testDir), workingDir = repoRoot())
      discard execCmdEx(quoteShell(cli) & " config set buddy-storage-path buddy-1 " & quoteShell(testDir / "keep"), env = cliEnv(testDir), workingDir = repoRoot())
      discard execCmdEx(quoteShell(cli) & " add-buddy --id buddy-1 --code CCCC-DDDD", env = cliEnv(testDir), workingDir = repoRoot())
      withCliEnv(testDir):
        let cfg = buddyconfig.loadConfig()
        check cfg.buddies.len == 1
        check cfg.buddies[0].pairingCode == "CCCC-DDDD"
        check cfg.buddies[0].storagePath == testDir / "keep"

  test "add-folder and config set append-only persist":
    withTestDir("clifoldercfg"):
      let cli = ensureCliBinary()
      let folderPath = testDir / "docs"
      createDir(folderPath)
      discard execCmdEx(quoteShell(cli) & " init", env = cliEnv(testDir), workingDir = repoRoot())
      let addResult = execCmdEx(
        quoteShell(cli) & " add-folder " & quoteShell(folderPath) & " --name docs",
        env = cliEnv(testDir),
        workingDir = repoRoot()
      )
      check addResult.exitCode == 0

      let cfgResult = execCmdEx(
        quoteShell(cli) & " config set folder-append-only docs on",
        env = cliEnv(testDir),
        workingDir = repoRoot()
      )
      check cfgResult.exitCode == 0

      withCliEnv(testDir):
        let cfg = buddyconfig.loadConfig()
        check cfg.folders.len == 1
        check cfg.folders[0].name == "docs"
        check cfg.folders[0].appendOnly

  test "sync-config reports recovery not enabled":
    withTestDir("clisyncconfig"):
      let cli = ensureCliBinary()
      discard execCmdEx(quoteShell(cli) & " init", env = cliEnv(testDir), workingDir = repoRoot())
      let result = execCmdEx(quoteShell(cli) & " sync-config", env = cliEnv(testDir), workingDir = repoRoot())
      check result.exitCode == 0
      check result.output.contains("Recovery not enabled")

  test "recover rejects invalid mnemonic":
    withTestDir("clirecoverinvalid"):
      let cli = ensureCliBinary()
      let result = execCmdEx(
        quoteShell(cli) & " recover",
        env = cliEnv(testDir),
        workingDir = repoRoot(),
        input = "not a valid mnemonic\n"
      )
      check result.exitCode == 0
      check result.output.contains("Invalid recovery phrase")

  test "export-recovery reports recovery not enabled":
    withTestDir("cliexportrecovery"):
      let cli = ensureCliBinary()
      discard execCmdEx(quoteShell(cli) & " init", env = cliEnv(testDir), workingDir = repoRoot())
      let result = execCmdEx(quoteShell(cli) & " export-recovery", env = cliEnv(testDir), workingDir = repoRoot())
      check result.exitCode == 0
      check result.output.contains("Recovery not enabled")
