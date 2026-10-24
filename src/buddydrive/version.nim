import std/strutils

const buildCommit {.strdefine.} = ""
  ## Set with -d:buildCommit=<id> where the source is not a git checkout,
  ## such as a Debian source package.

proc nimbleVersion(): string {.compileTime.} =
  for line in staticRead("../../buddydrive.nimble").splitLines():
    let parts = line.split("=", 1)
    if parts.len == 2 and parts[0].strip() == "version":
      return parts[1].strip().strip(chars = {'"'})
  "unknown"

proc gitCommit(): string {.compileTime.} =
  let (commit, code) = gorgeEx("git rev-parse --short=7 HEAD")
  if code != 0:
    return "unknown"
  result = commit.strip()
  let (changes, statusCode) = gorgeEx("git status --porcelain --untracked-files=no")
  if statusCode == 0 and changes.strip().len > 0:
    result.add("-dirty")

const
  BuddyDriveVersion* = nimbleVersion()
  BuildCommit* = (if buildCommit.len > 0: buildCommit else: gitCommit())
  BuildTime* = CompileDate & "T" & CompileTime & "Z"
    ## UTC, as Nim's CompileDate and CompileTime are.
  BuildId* = BuddyDriveVersion & " (" & BuildCommit & ", built " & BuildTime & ")"
