## A parallel, mega-binary test runner for BuddyDrive.
##
## `testament pattern` compiles and runs one test file at a time. That costs
## about 24 minutes here, and almost none of it is the tests: compiling a
## single test binary takes 35-115 s even with a warm cache and nothing to
## recompile, because Nim's frontend has to re-analyse chronos, libp2p and
## libsodium for every one of the 24 test files. The tests themselves add up to
## a few minutes.
##
## So this runner shards the test files into a handful of groups, generates one
## module per group that imports its files, and compiles and runs those few
## binaries in parallel. Units go into ~6 shards and integration tests into ~4,
## all at once, which turns the frontend cost into a single pass instead of 24.
##
## Usage:
##   testrunner pattern "tests/unit/*/*.nim"
##   testrunner pattern "tests/integration/*.nim" --jobs:4
##   testrunner pattern "tests/unit/*/*.nim" --mode:file        # one binary per file
##   testrunner pattern "tests/unit/*/*.nim" --filter:session
##   testrunner pattern "tests/unit/*/*.nim" --list
##
## Options:
##   --jobs:N       number of shards (default: see defaultJobs)
##   --mode:shard   combine files into N binaries (default)
##   --mode:file    one binary per test file, for bisecting
##   --timeout:S    kill a shard that runs longer than S seconds (default 600)
##   --filter:TEXT  only run test files whose path contains TEXT
##   --list         list the discovered test files and exit
##   --verbose      show the output of passing shards too

import std/[algorithm, os, osproc, sequtils, strformat, strutils, times]

const
  RunTimeout = 600.0
  CompileTimeout = 900.0
  PollIntervalMs = 25

type
  Phase = enum
    phCompile, phRun

  Outcome = enum
    ocPending, ocPass, ocFail, ocTimeout

  Job = ref object
    label: string
    files: seq[string]
    binary: string
    cacheDir: string
    modulePath: string
    logPath: string
    phase: Phase
    process: Process
    started: float
    timeout: float
    outcome: Outcome
    duration: float

  Config = object
    patternPlaceholder: string
    jobs: int
    timeout: float
    filter: string
    verbose: bool
    mode: string

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc quoteSh(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc formatSeconds(value: float): string =
  if value < 10.0:
    &"{value:.2f} sec"
  else:
    &"{value:.1f} sec"

proc expandPattern(pattern: string): seq[string] =
  result = toSeq(walkPattern(pattern)).filterIt(it.endsWith(".nim"))
  result.sort()

proc weight(path: string): float =
  ## Only used to spread the files over the shards. Compiling dominates and
  ## costs about the same per file, so file size just breaks ties. It is
  ## deliberately a pure function of the tree: an estimate that changed as runs
  ## were measured would re-shard into different modules and throw away every
  ## cache, which costs far more than an even split saves.
  max(float(getFileSize(path)) / 8192.0, 1.0)

proc shard(files: seq[string], count: int): seq[seq[string]] =
  ## Longest-processing-time-first: heaviest file into the lightest shard.
  let ordered = files.sortedByIt(-weight(it))
  result = newSeq[seq[string]](count)
  var loads = newSeq[float](count)
  for path in ordered:
    var lightest = 0
    for index in 1 ..< count:
      if loads[index] < loads[lightest]:
        lightest = index
    result[lightest].add(path)
    loads[lightest] += weight(path)

proc suiteTag(pattern: string): string =
  ## Namespace for the generated modules, binaries and caches. Unit and
  ## integration runs shard into the same number of pieces, so without this
  ## they would overwrite each other's modules and throw away the caches.
  let first = pattern.split('/')[1]
  if first.len > 0: first else: "tests"

proc moduleFor(root: string, tag: string, shardIndex: int, files: seq[string]): string =
  let modulePath = root / "testresults" / "mega" / (tag & "_shard_" & $shardIndex & ".nim")
  createDir(modulePath.parentDir())
  var body = "import std/unittest\n"
  for path in files:
    body.add "import ../../" & path.changeFileExt("") & "\n"
  writeFile(modulePath, body)
  result = modulePath

proc compileCommand(modulePath, cacheDir, binary: string, verbose: bool): string =
  var parts = @["nim", "c", "--hints:off", "-d:testing",
                "--nimCache:" & quoteSh(cacheDir),
                "-o:" & quoteSh(binary),
                quoteSh(modulePath)]
  if not verbose:
    parts.insert("--warnings:off", 3)
  parts.join(" ")

proc launch(job: Job, root: string, command: string) =
  createDir(job.logPath.parentDir())
  let full = command & " > " & quoteSh(job.logPath) & " 2>&1"
  job.process = startProcess("/bin/sh", workingDir = root, args = ["-c", full], options = {})
  job.started = epochTime()

proc logTail(path: string, maxLines = 60): string =
  if not fileExists(path):
    return ""
  let lines = readFile(path).splitLines()
  let tail = lines[max(0, lines.len - maxLines) .. ^1]
  result = tail.join("\n").strip()

proc elapsed(job: Job): float =
  epochTime() - job.started

proc stopJob(job: Job) =
  if job.process == nil:
    return
  terminate(job.process)
  if waitForExit(job.process, 5000) == -1:
    kill(job.process)
    discard waitForExit(job.process, 2000)
  close(job.process)
  job.process = nil

proc finish(job: Job): int =
  result = waitForExit(job.process)
  close(job.process)
  job.process = nil

proc newestSourceTime(root: string): float =
  result = 0.0
  for path in walkDirRec(root / "src", yieldFilter = {pcFile}):
    result = max(result, getLastModificationTime(path).toUnixFloat())
  for name in ["config.nims", "buddydrive.nimble", "nimble.paths"]:
    let path = root / name
    if fileExists(path):
      result = max(result, getLastModificationTime(path).toUnixFloat())

proc ensureCliBinary(root: string, verbose: bool) =
  ## The integration tests drive the real binary. Build it once into a stable
  ## path with a stable nimcache so the shards share one build rather than each
  ## doing a cold build of its own.
  let binary = root / "testresults" / "bin" / "buddydrive"
  let cache = root / "nimcache" / "buddydrive-cli"
  let logPath = root / "testresults" / "logs" / "buddydrive-cli-build.log"
  var needed = not fileExists(binary)
  if not needed:
    needed = newestSourceTime(root) > getLastModificationTime(binary).toUnixFloat()
  if needed:
    var parts = @["nim", "c", "--hints:off",
                  "--nimCache:" & quoteSh(cache),
                  "-o:" & quoteSh(binary), "src/buddydrive.nim"]
    if not verbose:
      parts.insert("--warnings:off", 3)
    createDir(logPath.parentDir())
    let started = epochTime()
    let outcome = execCmdEx(parts.join(" ") & " > " & quoteSh(logPath) & " 2>&1", workingDir = root)
    if outcome.exitCode != 0:
      echo "The buddydrive binary the integration tests drive failed to build:"
      echo logTail(logPath, 80)
      quit(1)
    echo &"built testresults/bin/buddydrive in {formatSeconds(epochTime() - started)}"
  putEnv("BUDDYDRIVE_TEST_CLI", binary)

proc parseArgs(): tuple[config: Config, pattern: string, list: bool] =
  result.config.timeout = RunTimeout
  result.config.mode = "shard"
  for arg in commandLineParams():
    if arg.startsWith("--jobs:"):
      result.config.jobs = parseInt(arg.split(':', 1)[1])
    elif arg.startsWith("--timeout:"):
      result.config.timeout = parseFloat(arg.split(':', 1)[1])
    elif arg.startsWith("--filter:"):
      result.config.filter = arg.split(':', 1)[1]
    elif arg == "--mode:shard":
      result.config.mode = "shard"
    elif arg == "--mode:file":
      result.config.mode = "file"
    elif arg == "--verbose":
      result.config.verbose = true
    elif arg == "--list":
      result.list = true
    elif arg == "pattern":
      discard
    elif result.pattern.len == 0:
      result.pattern = arg
    else:
      quit("Unexpected argument: " & arg, 2)
  if result.pattern.len == 0:
    quit("Usage: testrunner pattern \"<glob>\" [--jobs:N] [--mode:shard|file]", 2)
  result.config.patternPlaceholder = result.pattern

proc defaultJobs(pattern: string, fileCount: int): int =
  let shards =
    if pattern.startsWith("tests/integration"): 4
    else: max(1, countProcessors() div 2)
  max(1, min(min(shards, fileCount), countProcessors()))

proc buildJobs(cf: Config, root: string, files: seq[string]): seq[Job] =
  let tag = suiteTag(cf.patternPlaceholder)
  if cf.mode == "file":
    for path in files:
      let binary = root / "testresults" / "bin" / path.changeFileExt("")
      result.add Job(
        label: path,
        files: @[path],
        binary: binary,
        cacheDir: root / "nimcache" / path.parentDir() / path.extractFilename(),
        modulePath: root / path,
        logPath: root / "testresults" / "logs" / (path.changeFileExt("") & ".log"),
      )
    return

  let count = if cf.jobs > 0: min(cf.jobs, files.len) else: defaultJobs(cf.patternPlaceholder, files.len)
  let groups = shard(files, count)
  for index, group in groups:
    if group.len == 0:
      continue
    let name = tag & "-shard-" & $index
    result.add Job(
      label: name & " (" & $group.len & " files)",
      files: group,
      binary: root / "testresults" / "bin" / name,
      cacheDir: root / "nimcache" / name,
      modulePath: moduleFor(root, tag, index, group),
      logPath: root / "testresults" / "logs" / (name & ".compile.log"),
    )

proc describeExit(code: int): string =
  ## A shard killed by a signal is almost always the machine running out of
  ## memory while several of them build the libp2p C and C++ dependencies at
  ## once, and a bare exit code hides that.
  if code == 143 or code == 128 + 15:
    "killed (SIGTERM)"
  elif code == 137 or code == 128 + 9:
    "killed (SIGKILL, likely out of memory)"
  elif code > 128:
    &"killed by signal {code - 128}"
  else:
    &"exit code {code}"

proc reportFailure(job: Job, kind: string) =
  echo &"FAIL: {job.label}  ({kind})"
  echo "      files: " & job.files.join(", ")
  let output = logTail(job.logPath)
  if output.len > 0:
    for line in output.splitLines():
      echo "      " & line

proc main() =
  let (cf, pattern, listOnly) = parseArgs()
  let root = repoRoot()
  var files = expandPattern(pattern)
  if cf.filter.len > 0:
    files = files.filterIt(it.contains(cf.filter))
  if files.len == 0:
    quit("No test files matched " & pattern, 2)
  if listOnly:
    for path in files:
      echo path
    quit(0)

  var jobs = buildJobs(cf, root, files)
  let shardCount = jobs.len

  if files.anyIt(it.startsWith("tests/integration")):
    ensureCliBinary(root, cf.verbose)

  var pending = jobs
  var running: seq[Job]
  let overallStart = epochTime()

  while pending.len > 0 or running.len > 0:
    while pending.len > 0 and running.len < min(shardCount, countProcessors()):
      let job = pending[0]
      pending.delete(0)
      createDir(job.binary.parentDir())
      launch(job, root, compileCommand(job.modulePath, job.cacheDir, job.binary, cf.verbose))
      job.phase = phCompile
      job.timeout = CompileTimeout
      running.add(job)

    sleep(PollIntervalMs)

    var index = 0
    while index < running.len:
      let job = running[index]
      if running(job.process):
        if elapsed(job) > job.timeout:
          stopJob(job)
          job.outcome = ocTimeout
          reportFailure(job, &"timed out after {job.timeout.int} sec")
          running.delete(index)
          continue
        inc index
        continue

      let code = finish(job)
      if job.phase == phCompile:
        if code != 0:
          job.outcome = ocFail
          reportFailure(job, "compile failed: " & describeExit(code))
          running.delete(index)
          continue
        job.phase = phRun
        job.timeout = cf.timeout
        job.logPath = root / "testresults" / "logs" / (job.label.split(' ')[0] & ".run.log")
        launch(job, root, quoteSh(job.binary))
        continue

      job.duration = elapsed(job)
      if code == 0:
        job.outcome = ocPass
        echo &"PASS: {job.label}  ({formatSeconds(job.duration)})"
        if cf.verbose:
          let output = logTail(job.logPath, 2000)
          if output.len > 0:
            for line in output.splitLines():
              echo "      " & line
      else:
        job.outcome = ocFail
        reportFailure(job, describeExit(code))
      running.delete(index)

  for job in running:
    stopJob(job)


  let failed = jobs.filterIt(it.outcome != ocPass)
  let wall = epochTime() - overallStart
  echo ""
  if failed.len == 0:
    echo &"{files.len} test files passed in {formatSeconds(wall)} ({shardCount} shards)"
    quit(0)
  for job in failed:
    let reason = case job.outcome
      of ocTimeout: "timed out"
      of ocFail: "failed"
      else: "did not run"
    echo &"  {job.label}: {reason}"
    for path in job.files:
      echo "    " & path
  echo &"{failed.len} of {jobs.len} shards failed in {formatSeconds(wall)}"
  quit(1)

main()
