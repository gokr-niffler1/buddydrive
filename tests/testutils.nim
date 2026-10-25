import std/[exitprocs, os, random, times]
import chronos
import ../src/buddydrive/p2p/protocol
import ../src/buddydrive/sync/session

proc setupTestDir*(baseName: string): string =
  randomize()
  result = getTempDir() / "buddydrive_test_" & baseName & "_" & $getTime().toUnix() & "_" & $rand(1_000_000)
  createDir(result)

proc cleanupTestDir*(testDir: string) =
  if dirExists(testDir):
    try:
      removeDir(testDir)
    except:
      discard

template withTestDir*(baseName: string, body: untyped): untyped =
  let testDir {.inject.} = setupTestDir(baseName)
  try:
    body
  finally:
    cleanupTestDir(testDir)

template withTestFile*(baseName, content: string, body: untyped): untyped =
  let testDir {.inject.} = setupTestDir(baseName)
  let testFilePath {.inject.} = testDir / "testfile"
  try:
    writeFile(testFilePath, content)
    body
  finally:
    cleanupTestDir(testDir)

proc makeFileInfo*(path: string, size: int64 = 0, mtime: int64 = 0): tuple[path: string, encryptedPath: string, size: int64, mtime: int64, hash: array[32, byte]] =
  result.path = path
  result.encryptedPath = path
  result.size = size
  result.mtime = mtime
  result.hash = default(array[32, byte])

proc useIsolatedDataDir*(name: string) =
  ## Points config and index storage at a fresh directory for this test
  ## process, so runs never inherit index rows (which drive move and delete
  ## detection) from an earlier run or from the developer's own ~/.buddydrive.
  let dir = setupTestDir("datadir_" & name)
  putEnv("BUDDYDRIVE_DATA_DIR", dir)
  putEnv("BUDDYDRIVE_CONFIG_DIR", dir)
  addExitProc(proc() = cleanupTestDir(dir))

proc getKvApiUrl*(): string =
  ## Empty means "use the in-process KV stub"; set it to test against a real
  ## deployment instead.
  getEnv("BUDDYDRIVE_KV_API_URL", "")

proc shortenSessionTimeouts*() =
  ## A session always waits out the session-end timeout and the linger timeout
  ## after its last message: ten seconds and two, because a real buddy may be
  ## slow to answer. Twenty-odd tests each running a session adds minutes of
  ## pure waiting to the suite, so shorten them. Fast tests deserve fast
  ## timeouts, not a duplicate of the production constants.
  messageIdleTimeout = chronos.milliseconds(500)
  folderListTimeout = chronos.seconds(2)
  sessionEndTimeout = chronos.milliseconds(200)
  sessionEndLingerTimeout = chronos.milliseconds(100)
