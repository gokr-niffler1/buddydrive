import std/[algorithm, options, sets, tables]
import std/os except FileInfo
import chronos
import libp2p/stream/connection
import ../types
import ../crypto
import ../config
import ../p2p/messages
import ../p2p/protocol
import transfer
import storage
import ../logutils

## A sync session between two buddies is two backups over one connection:
## each side's folders are stored, encrypted, on the other side. The side that
## owns a folder is the only authority on it; the storage side keeps what it is
## told to keep and never deletes on its own.
##
## The conversation is strictly alternating, which an unbuffered transport
## needs. After the owner lists are exchanged, the folders of the buddy with
## the lower UUID are handled first, then those of the other.

proc backupBuddies(config: AppConfig, folder: FolderConfig): seq[string] =
  ## Every configured buddy this folder is backed up to.
  for buddy in config.buddies:
    if folderAppliesToBuddy(folder, buddy.id.uuid):
      result.add(buddy.id.uuid)

proc applicableFolders(config: AppConfig, buddyId: string): seq[FolderConfig] =
  ## An encrypted folder without a usable key is left out rather than sent in
  ## plain form; the daemon gives such folders a key at startup.
  for folder in config.folders:
    if folder.encrypted and folder.folderKey.len != KeySize:
      continue
    if folderAppliesToBuddy(folder, buddyId):
      result.add(folder)
  result.sort(proc(a, b: FolderConfig): int = cmp(folderWireId(a), folderWireId(b)))

proc logSession(message: string) =
  {.cast(gcsafe).}:
    try:
      logWarn("Sync: " & message)
    except Exception:
      discard

proc sessionFailed(reason: string): bool =
  ## Every way a session can give up says why; a bare "failed" is useless
  ## when two machines are involved.
  logSession("stopped: " & reason)
  false

const
  SessionEndTimeout = chronos.seconds(10)
  SessionEndLingerTimeout = chronos.seconds(2)

type
  FolderOutcome* = enum
    foSynced
    foSkipped
    foRefused

  FolderReport* = object
    folderName*: string
    outcome*: FolderOutcome
    reason*: string

  SessionReport* = ref object
    ## What became of each of our folders in one session, for the GUIs.
    ## Folders not listed did not get their turn: the session ended first.
    folders*: seq[FolderReport]

  OwnedFolder = object
    transfer: FileTransfer
    files: seq[FileInfo]
    backupBuddies: seq[string]
    restoreUnknown: bool

  MoveInstruction = tuple[oldPath: string, newPath: string, hash: string]

  OwnerPlan = object
    moves: seq[MoveInstruction]
    deletes: seq[string]
    restores: seq[FileInfo]

proc note(report: SessionReport, folderName: string, outcome: FolderOutcome, reason = "") =
  if report != nil:
    report.folders.add(FolderReport(folderName: folderName, outcome: outcome, reason: reason))

proc sendOwnerLists(
    owned: seq[OwnedFolder],
    conn: Connection,
    protocol: SyncProtocol,
    ownerMachine: string,
    takeover: bool,
): Future[bool] {.async.} =
  for folder in owned:
    if not await folder.transfer.sendFileList(conn, folder.files, ownerMachine, takeover):
      return sessionFailed("could not send the file list of " & folder.transfer.scanner.folder.name)
  try:
    await protocol.sendMessage(conn, newSyncDone())
    true
  except CatchableError as e:
    sessionFailed("could not finish sending file lists: " & e.msg)

proc receiveOwnerLists(conn: Connection, protocol: SyncProtocol): Future[seq[ProtocolMessage]] {.async.} =
  var seen = initHashSet[string]()
  while true:
    let msgOpt = await protocol.receiveMessage(conn, folderListTimeout)
    if msgOpt.isNone():
      raise newException(CatchableError, "failed to receive buddy folder lists")

    let msg = msgOpt.get()
    case msg.kind
    of msgFileList:
      if msg.folderId.len == 0 or msg.folderId in seen:
        raise newException(CatchableError, "buddy sent an unusable folder list")
      seen.incl(msg.folderId)
      result.add(msg)
    of msgSyncDone:
      result.sort(proc(a, b: ProtocolMessage): int = cmp(a.folderId, b.folderId))
      return
    else:
      raise newException(CatchableError, "unexpected message while receiving folder lists")

proc sameMoveCandidate(stored: FileInfo, local: FileInfo): bool =
  stored.hash == local.hash and
  stored.size == local.size and
  stored.mode == local.mode and
  stored.symlinkTarget == local.symlinkTarget

proc readableStored(transfer: FileTransfer, stored: seq[FileInfo]): seq[FileInfo] =
  ## Fills in the plaintext path and symlink target of what the storage buddy
  ## holds. Entries we cannot open are not ours to act on and are dropped.
  let folder = transfer.scanner.folder
  for entry in stored:
    var info = entry
    if transfer.isEncryptedOnWire():
      try:
        info.path = decryptPath(entry.encryptedPath, folder.folderKey)
        if entry.symlinkTarget.len > 0:
          info.symlinkTarget = decryptSymlinkTarget(entry.symlinkTarget, folder.folderKey)
      except CatchableError:
        continue
    else:
      info.path = entry.encryptedPath
    result.add(info)

proc wireView(transfer: FileTransfer, files: seq[FileInfo]): seq[FileInfo] =
  ## Our files with their content hashes as the storage buddy knows them, so
  ## the two lists can be compared.
  for info in files:
    var wired = info
    wired.hash = transfer.wireHash(info.hash)
    result.add(wired)

proc adoptPlainHashes(transfer: FileTransfer, localFiles: seq[FileInfo], stored: var seq[FileInfo]): seq[tuple[path: string, hash: string]] =
  ## Backups made before content hashes were keyed hold the plain hash. Where
  ## one matches a file we have, the buddy is told the keyed hash instead,
  ## which spares sending the file again.
  if not transfer.isEncryptedOnWire():
    return
  var plainHashes = initHashSet[string]()
  for info in localFiles:
    plainHashes.incl(hashToString(info.hash))
  for held in stored.mitems:
    if hashToString(held.hash) in plainHashes:
      held.hash = transfer.wireHash(held.hash)
      result.add((held.encryptedPath, hashToString(held.hash)))

proc computeOwnerPlan(transfer: FileTransfer, localFiles: seq[FileInfo], stored: seq[FileInfo], restoreUnknown: bool): OwnerPlan =
  ## Works out what the storage buddy should change to match us, and what it
  ## holds that we should take back. A stored path we do not have is only
  ## deleted when our index shows we once held it. Otherwise it is restored
  ## when restoreUnknown is set (a takeover, after 'recover' or 'takeover'),
  ## which is how a lost or new machine gets its files back, and ignored in
  ## every other session, so a buddy cannot put files into our folders.
  var localByPath = initTable[string, FileInfo]()
  var localByHash = initTable[string, FileInfo]()
  var storedByPath = initTable[string, FileInfo]()
  var knownPaths = initHashSet[string]()
  var claimedTargets = initHashSet[string]()

  for info in localFiles:
    localByPath[info.encryptedPath] = info
    let key = hashToString(info.hash)
    if key notin localByHash:
      localByHash[key] = info

  for info in stored:
    storedByPath[info.encryptedPath] = info

  for info in transfer.index.getAllFiles():
    knownPaths.incl(info.encryptedPath)

  var storedPaths: seq[string] = @[]
  for path in storedByPath.keys:
    storedPaths.add(path)
  storedPaths.sort(cmp)

  let appendOnly = transfer.scanner.folder.appendOnly
  for path in storedPaths:
    if path in localByPath:
      continue
    let held = storedByPath[path]
    let key = hashToString(held.hash)

    if not appendOnly and key in localByHash:
      let local = localByHash[key]
      if local.encryptedPath notin storedByPath and local.encryptedPath notin claimedTargets and
          sameMoveCandidate(held, local):
        result.moves.add((path, local.encryptedPath, key))
        claimedTargets.incl(local.encryptedPath)
        continue

    if path in knownPaths:
      if not appendOnly:
        result.deletes.add(path)
    elif restoreUnknown:
      result.restores.add(held)

proc ownerServePhase(folder: OwnedFolder, conn: Connection): Future[bool] {.async.} =
  ## Hands the storage buddy the files it asks for, by their encrypted path.
  let transfer = folder.transfer
  var pathsByWireName = initTable[string, string]()
  for info in folder.files:
    pathsByWireName[info.encryptedPath] = info.path

  let folderName = transfer.scanner.folder.name
  while true:
    let msgOpt = await transfer.protocol.receiveMessage(conn)
    if msgOpt.isNone():
      return sessionFailed("connection lost while the buddy fetched " & folderName)

    let msg = msgOpt.get()
    case msg.kind
    of msgSyncDone:
      return true
    of msgFileRequest:
      if msg.requestPath notin pathsByWireName:
        try:
          await transfer.protocol.sendMessage(conn, newFileAck(false))
        except CatchableError:
          return sessionFailed("connection lost while the buddy fetched " & folderName)
      else:
        let path = pathsByWireName[msg.requestPath]
        if not await transfer.sendFileData(conn, path, msg.requestOffset, msg.requestLength):
          logSession("could not send " & folderName & "/" & path & " to the buddy")
    else:
      return sessionFailed("unexpected " & $msg.kind & " while the buddy fetched " & folderName)

proc ownerSyncFolder(folder: OwnedFolder, buddyId: string, conn: Connection, report: SessionReport): Future[bool] {.async.} =
  let transfer = folder.transfer
  let folderName = transfer.scanner.folder.name
  let folderId = folderWireId(transfer.scanner.folder)
  try:
    await transfer.protocol.sendMessage(conn, newListPathsRequest(folderId))
  except CatchableError as e:
    return sessionFailed("could not ask what the buddy stores of " & folderName & ": " & e.msg)
  let answer = await transfer.protocol.receiveMessage(conn)
  if answer.isNone():
    return sessionFailed("the buddy did not say what it stores of " & folderName)
  if answer.get().kind == msgFolderRefused:
    # Nothing is changed on either side; the folder simply waits.
    logSession("the buddy refused " & folderName & ": " & answer.get().refusedReason)
    report.note(folderName, foRefused, answer.get().refusedReason)
    return true
  if answer.get().kind != msgListPathsResponse or answer.get().listResponseFolderId != folderId:
    return sessionFailed("unexpected answer about what the buddy stores of " & folderName)
  var listed: seq[FileInfo] = @[]
  for entry in answer.get().listFiles:
    listed.add(toFileInfo(entry))
  var stored = readableStored(transfer, listed)

  let rehashes =
    try:
      adoptPlainHashes(transfer, folder.files, stored)
    except CatchableError as e:
      return sessionFailed("could not compare " & folderName & " with the buddy's copy: " & e.msg)
  let plan =
    try:
      computeOwnerPlan(transfer, wireView(transfer, folder.files), stored, folder.restoreUnknown)
    except CatchableError as e:
      return sessionFailed("could not compare " & folderName & " with the buddy's copy: " & e.msg)

  for rehash in rehashes:
    try:
      await transfer.protocol.sendMessage(conn, newRehash(rehash.path, rehash.hash))
    except CatchableError:
      return false

  for move in plan.moves:
    try:
      await transfer.protocol.sendMessage(conn, newMoveFile(move.oldPath, move.newPath, move.hash))
    except CatchableError:
      return false

  for path in plan.deletes:
    try:
      await transfer.protocol.sendMessage(conn, newFileDelete(path))
    except CatchableError:
      return false

  for held in plan.restores:
    let target = safeJoin(transfer.scanner.rootPath, held.path)
    if target.isNone or fileExists(target.get()) or symlinkExists(target.get()):
      continue
    if not await transfer.syncFile(conn, held, held.encryptedPath):
      logSession("could not restore " & folderName & "/" & held.path & " from the buddy")

  try:
    await transfer.protocol.sendMessage(conn, newSyncDone())
  except CatchableError:
    return false

  if not await ownerServePhase(folder, conn):
    return false

  # This buddy has now been told about every deletion. A tombstone goes once
  # all the folder's buddies have been. An append-only folder keeps them: they
  # are what stops a file we deleted here from being restored from the
  # archive again.
  if not transfer.scanner.folder.appendOnly:
    transfer.pruneConfirmedDeletes(buddyId, folder.backupBuddies)
  report.note(folderName, foSynced)
  true

proc storageOwnerPhase(storage: StorageFolder, conn: Connection): Future[bool] {.async.} =
  ## Carries out the owner's instructions and answers its restore requests.
  let folderName = storage.folderName
  while true:
    let msgOpt = await storage.protocol.receiveMessage(conn)
    if msgOpt.isNone():
      return sessionFailed("connection lost while the buddy updated its " & folderName)

    let msg = msgOpt.get()
    case msg.kind
    of msgSyncDone:
      return true
    of msgListPathsRequest:
      if msg.listFolderId != storage.folderId:
        return sessionFailed("the buddy asked about folder " & msg.listFolderId & " while syncing " & folderName)
      var entries: seq[FileEntry] = @[]
      for info in storage.listStored():
        entries.add(toFileEntry(info))
      try:
        await storage.protocol.sendMessage(conn, newListPathsResponse(storage.folderId, entries))
      except CatchableError as e:
        return sessionFailed("could not list what we store of " & folderName & ": " & e.msg)
    of msgMoveFile:
      if not storage.applyMove(msg.oldPath, msg.newPath):
        logSession("could not rename a stored file of the buddy's " & folderName &
          "; it will be fetched again under its new name")
    of msgRehash:
      if not storage.applyRehash(msg.rehashPath, msg.rehashHash):
        logSession("could not update a stored hash of the buddy's " & folderName &
          "; the file will be fetched again")
    of msgFileDelete:
      if not storage.applyDelete(msg.deletedPath):
        logSession("could not delete a stored file of the buddy's " & folderName)
    of msgFileRequest:
      if not await storage.serveRestore(conn, msg.requestPath, msg.requestOffset, msg.requestLength):
        logSession("could not send a stored file of " & folderName & " back to the buddy")
    else:
      return sessionFailed("unexpected " & $msg.kind & " while the buddy updated its " & folderName)

proc storageFetchPhase(storage: StorageFolder, conn: Connection, ownerFiles: seq[FileInfo]): Future[bool] {.async.} =
  let work = storage.filesToFetch(ownerFiles)
  var failures = 0
  for info in work.fetch:
    if not await storage.storeFromOwner(conn, info):
      inc failures
  if failures > 0:
    logSession("could not store " & $failures & " of " & $work.fetch.len & " files of the buddy's " & storage.folderName)
  for info in work.metadata:
    if not storage.updateMetadata(info):
      logSession("could not update the stored mode or time of a file of the buddy's " & storage.folderName)

  try:
    await storage.protocol.sendMessage(conn, newSyncDone())
    true
  except CatchableError as e:
    sessionFailed("connection lost after storing the buddy's " & storage.folderName & ": " & e.msg)

proc runOwnerRound(owned: seq[OwnedFolder], buddyId: string, conn: Connection, report: SessionReport): Future[bool] {.async.} =
  for folder in owned:
    if not await ownerSyncFolder(folder, buddyId, conn, report):
      return false
  true

proc runStorageRound(
    config: AppConfig,
    buddyId: string,
    listings: seq[ProtocolMessage],
    conn: Connection,
    protocol: SyncProtocol,
): Future[bool] {.async.} =
  for listing in listings:
    let ownership = decideOwnership(config, buddyId, listing)
    if ownership.note.len > 0:
      logSession(ownership.note)
    if not ownership.accepted:
      # Answer the owner's first question with a refusal and move on together.
      let request = await protocol.receiveMessage(conn)
      if request.isNone() or request.get().kind != msgListPathsRequest or
          request.get().listFolderId != listing.folderId:
        return sessionFailed("unexpected message while refusing the buddy's " & listing.folderName)
      try:
        await protocol.sendMessage(conn, newFolderRefused(listing.folderId, ownership.note))
      except CatchableError as e:
        return sessionFailed("could not refuse the buddy's " & listing.folderName & ": " & e.msg)
      continue

    let storage =
      try:
        newStorageFolder(config, buddyId, listing, protocol)
      except CatchableError as e:
        return sessionFailed("could not prepare storage for the buddy's " & listing.folderName & ": " & e.msg)
    defer: storage.close()

    var ownerFiles: seq[FileInfo] = @[]
    for entry in listing.files:
      ownerFiles.add(toFileInfo(entry))

    if not await storageOwnerPhase(storage, conn):
      return false
    if not await storageFetchPhase(storage, conn, ownerFiles):
      return false
  true

proc receiveSessionEnd(conn: Connection, protocol: SyncProtocol, timeout: Duration): Future[bool] {.async.} =
  ## Reads until the buddy's session-end marker, the connection closes, or we
  ## give up. Anything else on the wire at this point is ignored rather than
  ## treated as an error: the session itself is already decided.
  let deadline = Moment.now() + timeout
  while true:
    let remaining = deadline - Moment.now()
    if remaining <= ZeroDuration:
      return false
    let msgOpt =
      try:
        await protocol.receiveMessage(conn).wait(remaining)
      except CatchableError:
        return false
    if msgOpt.isNone():
      return false
    if msgOpt.get().kind == msgSessionEnd:
      return true

proc awaitSessionEnd(conn: Connection, protocol: SyncProtocol, endsFirst: bool) {.async.} =
  ## Closes the session down in a fixed order, so neither side hangs up while
  ## the other still has bytes in flight.
  ##
  ## Whichever side finished its phases first used to close immediately, while
  ## the other was still waiting for a file ack and the final sync-done. A relay
  ## tears down both halves when one closes and drops whatever it still had
  ## buffered, so the slower side saw a truncated stream and reported failure on
  ## a sync that had in fact transferred everything. On loopback the bytes are
  ## always flushed already, which is why this only showed up over a real link.
  ##
  ## The same UUID comparison that orders the delta phases decides who speaks
  ## first here, keeping the conversation strictly alternating — a simultaneous
  ## exchange deadlocks on an unbuffered transport. The responder then waits for
  ## the initiator to hang up, so the last marker cannot be cut off either.
  ##
  ## Never fails the session: a buddy that predates this message just leaves us
  ## waiting for the timeout.
  if endsFirst:
    try:
      await protocol.sendMessage(conn, newSessionEnd())
    except CatchableError:
      return
    discard await receiveSessionEnd(conn, protocol, SessionEndTimeout)
  else:
    discard await receiveSessionEnd(conn, protocol, SessionEndTimeout)
    try:
      await protocol.sendMessage(conn, newSessionEnd())
    except CatchableError:
      return
    # Wait for the initiator to hang up before we do.
    discard await receiveSessionEnd(conn, protocol, SessionEndLingerTimeout)


proc syncBuddyFolders*(
    config: AppConfig,
    buddyId: string,
    conn: Connection,
    protocol: SyncProtocol,
    ownerMachine = "",
    takeover = false,
    report: SessionReport = nil,
): Future[bool] {.async.} =
  ## ownerMachine defaults to this installation's machine id. takeover claims
  ## our folders at this buddy even if another machine owns them there, and
  ## is the only session that restores files we have no record of.
  ## report, when given, collects the outcome of each of our folders.
  let machine =
    if ownerMachine.len > 0: ownerMachine
    else:
      try:
        {.cast(gcsafe).}:
          machineId()
      except Exception as e:
        logSession("cannot read this machine's id (" & e.msg & "); buddies cannot tell it " &
          "from another machine with the same identity")
        ""
  var owned: seq[OwnedFolder] = @[]
  defer:
    for folder in owned:
      folder.transfer.close()
  var sentIds = initTable[string, string]()
  for folder in applicableFolders(config, buddyId):
    let wireId = folderWireId(folder)
    if wireId in sentIds:
      # The buddy rejects a second list with the same id, which would end
      # the session for every folder.
      let reason = "it has the same id as folder " & sentIds[wireId] & " in config.toml"
      logSession("skipping " & folder.name & ": " & reason)
      report.note(folder.name, foSkipped, reason)
      continue
    sentIds[wireId] = folder.name
    var transfer: FileTransfer
    try:
      transfer = newFileTransfer(folder, protocol, config.bandwidthLimitKBps)
      owned.add(OwnedFolder(
        transfer: transfer,
        files: transfer.scanner.scanDirectoryStrict(),
        backupBuddies: backupBuddies(config, folder),
        restoreUnknown: takeover,
      ))
    except CatchableError as e:
      # Left out of this session entirely, so the buddy keeps its copy as is.
      if transfer != nil:
        transfer.close()
      logSession("skipping " & folder.name & " this time: " & e.msg)
      report.note(folder.name, foSkipped, e.msg)

  let sendListsFut = sendOwnerLists(owned, conn, protocol, machine, takeover)
  let listings = await receiveOwnerLists(conn, protocol)
  if not await sendListsFut:
    return false

  let ownFoldersFirst = config.buddy.uuid < buddyId
  var allOk =
    if ownFoldersFirst:
      await runOwnerRound(owned, buddyId, conn, report)
    else:
      await runStorageRound(config, buddyId, listings, conn, protocol)
  if allOk:
    allOk =
      if ownFoldersFirst:
        await runStorageRound(config, buddyId, listings, conn, protocol)
      else:
        await runOwnerRound(owned, buddyId, conn, report)

  await awaitSessionEnd(conn, protocol, ownFoldersFirst)
  allOk
