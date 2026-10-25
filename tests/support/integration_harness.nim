import std/[exitprocs, hashes, httpclient, net, os, osproc, strutils, times]

proc repoRoot*(): string =
  currentSourcePath().parentDir().parentDir().parentDir()

proc portLockPath(port: int): string =
  getTempDir() / ("buddydrive_port_" & $port)

proc reservePort(port: int): bool =
  ## Ports are reserved with a directory, which stdlib's createDir creates
  ## atomically, so two test processes starting at the same moment cannot be
  ## handed the same number by the OS.
  let lock = portLockPath(port)
  if dirExists(lock):
    try:
      if getLastModificationTime(lock).toUnixFloat() < epochTime() - 3600.0:
        removeDir(lock)
      else:
        return false
    except OSError:
      return false
  try:
    createDir(lock)
    result = true
  except OSError:
    result = false

proc releasePort(port: int) =
  try:
    removeDir(portLockPath(port))
  except OSError:
    discard

proc freePort*(): int =
  ## A port this process owns until it exits. Tests run several at a time, so
  ## the number has to be reserved rather than merely sampled.
  for _ in 0 ..< 50:
    var chosen = 0
    let sock = newSocket()
    try:
      sock.bindAddr(Port(0))
      chosen = int(sock.getLocalAddr()[1])
    except OSError:
      discard
    finally:
      sock.close()
    if chosen == 0:
      continue
    if reservePort(chosen):
      addExitProc(proc() = releasePort(chosen))
      return chosen
  doAssert false, "could not reserve a free port"

proc newestSourceTime(root: string): float =
  result = 0.0
  for path in walkDirRec(root / "src", yieldFilter = {pcFile}):
    result = max(result, getLastModificationTime(path).toUnixFloat())
  for name in ["config.nims", "buddydrive.nimble", "nimble.paths"]:
    let path = root / name
    if fileExists(path):
      result = max(result, getLastModificationTime(path).toUnixFloat())

proc cliBinaryPath(root, outputPrefix, buildCommandTemplate: string): string =
  ## The name carries the build command, so two tests that want differently
  ## built binaries get one each instead of racing for the same file.
  root / "testresults" / "bin" / (outputPrefix & "-" & ($hash(buildCommandTemplate))[0 ..< 8])

proc buildCliBinary(root, binary, buildCommandTemplate: string): bool =
  let cache = root / "nimcache" / ("cli-" & $extractFilename(binary))
  let logPath = binary & ".build.log"
  createDir(binary.parentDir())
  let command = buildCommandTemplate
    .replace("$OUT", quoteShell(binary))
    .replace("$CACHE", quoteShell(cache))
  let build = execCmdEx(command & " > " & quoteShell(logPath) & " 2>&1", workingDir = root)
  if build.exitCode != 0:
    echo readFile(logPath)
  result = build.exitCode == 0

proc ensureBuiltBinary*(cachedPath: var string, outputPrefix, buildCommandTemplate: string): string =
  ## Integration tests drive the real binary. It is built once into a stable
  ## place with a stable nimcache, so every test process shares the build and
  ## a repeat run only relinks. The runner sets BUDDYDRIVE_TEST_CLI after
  ## building it once for the whole suite.
  if cachedPath.len == 0:
    let root = repoRoot()
    let fromRunner = getEnv("BUDDYDRIVE_TEST_CLI", "")
    if fromRunner.len > 0 and fileExists(fromRunner):
      cachedPath = fromRunner
    else:
      let binary = cliBinaryPath(root, outputPrefix, buildCommandTemplate)
      let stale = not fileExists(binary) or
        newestSourceTime(root) > getLastModificationTime(binary).toUnixFloat()
      if stale:
        if not buildCliBinary(root, binary, buildCommandTemplate):
          doAssert false, "could not build " & binary
      cachedPath = binary
  result = cachedPath

proc waitForTcpReady*(host: string, port: int, retries = 40, delayMs = 100) =
  for _ in 0 ..< retries:
    try:
      let sock = newSocket(buffered = true)
      defer: sock.close()
      sock.connect(host, Port(port))
      return
    except OSError:
      sleep(delayMs)
  doAssert false, "TCP service did not become ready"

proc waitForHttpReady*(url: string, retries = 50, delayMs = 100) =
  let client = newHttpClient()
  defer: client.close()
  for _ in 0 ..< retries:
    try:
      let resp = client.get(url)
      if resp.code == Http200:
        return
    except CatchableError:
      discard
    sleep(delayMs)
  doAssert false, "HTTP service did not become ready"

proc stopProcessCleanly*(process: Process) =
  if process == nil:
    return
  if peekExitCode(process) == -1:
    terminate(process)
    discard waitForExit(process, 5000)
  close(process)
