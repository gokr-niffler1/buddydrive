import std/times

const DefaultP2PPort* = 41721

type
  RecoveryConfig* = object
    enabled*: bool
    publicKeyB58*: string
    masterKey*: string

  BuddyId* = object
    uuid*: string
    name*: string
  
  BuddyInfo* = object
    id*: BuddyId
    pairingCode*: string
    addresses*: seq[string]
    syncWindow*: string
    syncInterval*: string
    storagePath*: string
    addedAt*: Time
  
  FolderConfig* = object
    id*: string
    name*: string
    path*: string
    encrypted*: bool
    appendOnly*: bool
    folderKey*: string
    buddies*: seq[string]
  
  AppConfig* = object
    buddy*: BuddyId
    recovery*: RecoveryConfig
    listenPort*: int
    announceAddr*: string
    apiBaseUrl*: string
    relayRegion*: string
    storageBasePath*: string
    bandwidthLimitKBps*: int
    guiLocale*: string
      ## BCP 47 tag the GUIs format dates and numbers with; empty = the browser's.
    folders*: seq[FolderConfig]
    buddies*: seq[BuddyInfo]
  
  FileInfo* = object
    path*: string
    encryptedPath*: string
    size*: int64
    mtime*: int64
    hash*: array[32, byte]
    mode*: int
    symlinkTarget*: string
  
  FileChangeKind* = enum
    fcAdded
    fcModified
    fcDeleted
    fcMoved
  
  FileChange* = object
    kind*: FileChangeKind
    info*: FileInfo
    oldPath*: string

  ConnectionState* = enum
    csDisconnected = "disconnected"
    csConnecting = "connecting"
    csConnected = "connected"
    csSyncing = "syncing"
    csError = "error"
  
  SyncStatus* = object
    folder*: string
    totalBytes*: int64
    syncedBytes*: int64
    fileCount*: int
    syncedFiles*: int
    status*: string
    detail*: string
    lastSync*: Time
  
  SyncRequestState* = object
    ## A sync asked for from a GUI, until it turns into a session or fails.
    buddyId*: string
    buddyName*: string
    requestedAt*: Time
    updatedAt*: Time
    state*: string
      ## "looking up", "dialing", "connected", "already syncing", "not found" or "unreachable"
    detail*: string

  SessionRecord* = object
    ## One connection with a buddy, as shown in the GUI's sync activity.
    id*: int
    buddyId*: string
    buddyName*: string
    dialedBy*: string
      ## "us" or "buddy"
    via*: string
      ## "direct" or "relay"
    startedAt*: Time
    endedAt*: Time
    outcome*: string
      ## "running", "ok", "failed", "turned away" or "interrupted"
    bytesSent*: int64
    bytesReceived*: int64
    filesSent*: int
    filesReceived*: int

  BuddyStatus* = object
    id*: string
    name*: string
    state*: ConnectionState
    latencyMs*: int
    lastSync*: Time
    nextSync*: Time
      ## When this machine next reaches out; the zero Time when it will not.
    intervalMinutes*: int
      ## The interval in effect, after defaults and the relay standby cap.
    buddyDials*: bool
      ## The buddy initiates; we only meet it at the relay.

proc `$`*(id: BuddyId): string =
  if id.name.len > 0:
    result = id.name & " (" & id.uuid[0..7] & "...)"
  else:
    result = id.uuid[0..7] & "..."

proc shortId*(id: string): string =
  if id.len > 8:
    result = id[0..7] & "..."
  else:
    result = id

proc newBuddyId*(uuid: string, name: string = ""): BuddyId =
  result.uuid = uuid
  result.name = name

proc newFolderConfig*(name, path: string, encrypted = true): FolderConfig =
  result.id = ""
  result.name = name
  result.path = path
  result.encrypted = encrypted
  result.appendOnly = false
  result.folderKey = ""
  result.buddies = @[]

proc newAppConfig*(buddy: BuddyId): AppConfig =
  result.buddy = buddy
  result.recovery.enabled = false
  result.recovery.publicKeyB58 = ""
  result.recovery.masterKey = ""
  result.listenPort = DefaultP2PPort
  result.announceAddr = ""
  result.apiBaseUrl = "https://api.buddydrive.org"
  result.relayRegion = "eu"
  result.storageBasePath = ""
  result.bandwidthLimitKBps = 0
  result.folders = @[]
  result.buddies = @[]
