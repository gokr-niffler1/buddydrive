import std/[os, strutils]
import ../../src/buddydrive/types
import ../../src/buddydrive/crypto

const
  BuddyOne* = "11111111-1111-1111-1111-111111111111"
  BuddyTwo* = "22222222-2222-2222-2222-222222222222"

proc syncFolder*(
    id: string,
    path: string,
    name = "docs",
    encrypted = true,
    appendOnly = false,
    folderKey = "",
): FolderConfig =
  result = newFolderConfig(name, path, encrypted)
  result.id = id
  result.appendOnly = appendOnly
  result.folderKey =
    if folderKey.len > 0: folderKey
    elif encrypted: generateKey()
    else: ""

proc peerConfig*(
    selfId: string,
    otherId: string,
    storagePath: string,
    folders: seq[FolderConfig],
    pairingCode = "",
): AppConfig =
  result = newAppConfig(newBuddyId(selfId, "peer-" & selfId[0 .. 3]))
  var buddy: BuddyInfo
  buddy.id = newBuddyId(otherId, "peer-" & otherId[0 .. 3])
  buddy.pairingCode = pairingCode
  buddy.storagePath = storagePath
  result.buddies = @[buddy]
  for folder in folders:
    var shared = folder
    shared.buddies = @[otherId]
    result.folders.add(shared)

proc storedFiles*(root: string, suffix: string): seq[string] =
  if not dirExists(root):
    return
  for path in walkDirRec(root, relative = true):
    if path.endsWith(suffix):
      result.add(path)

proc anyFileMentions*(root: string, needles: openArray[string]): bool =
  ## True when any file under root has one of the needles in its name or
  ## its content.
  if not dirExists(root):
    return false
  for path in walkDirRec(root, relative = false):
    let content = try: readFile(path) except IOError: ""
    for needle in needles:
      if needle in path.relativePath(root) or needle in content:
        return true
  false
