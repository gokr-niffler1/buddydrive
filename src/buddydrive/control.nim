import std/[json, net, os, strutils, tables, times, options, uri]
import chronos
import db_connector/db_sqlite
import types
import config
import crypto
import control_web
import recovery
import sync/config_sync
import sync/policy
import version
import p2p/messages

const
  DefaultControlPort* = 17521

var controlStarted = false
var controlThread: Thread[int]
var pendingRecoveryWords: seq[string] = @[]
var storageUsageMaxAge* = initDuration(seconds = 60)
  ## How long /storage reuses a buddy's totals. The GUI asks every few
  ## seconds, and counting means walking everything the buddy stores.
var storageUsageCache = initTable[string, tuple[files: int, bytes: int64, at: Time]]()

proc getStateDb(): DbConn =
  let path = config.getDataDir() / "state.db"
  result = open(path, "", "", "")
  # The control thread reads while the daemon writes; wait for the other
  # instead of failing at once.
  result.exec(sql"PRAGMA busy_timeout = 5000")
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS runtime_status (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      peer_id TEXT,
      addresses TEXT,
      running INTEGER,
      started_at INTEGER
    )
  """)
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS buddy_state (
      id TEXT PRIMARY KEY,
      name TEXT,
      state TEXT,
      latency_ms INTEGER,
      last_activity TEXT
    )
  """)
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS folder_state (
      name TEXT PRIMARY KEY,
      total_bytes INTEGER,
      synced_bytes INTEGER,
      file_count INTEGER,
      synced_files INTEGER,
      status TEXT,
      detail TEXT,
      last_sync TEXT
    )
  """)
  var folderColumns: seq[string] = @[]
  for row in result.rows(sql"PRAGMA table_info(folder_state)"):
    folderColumns.add(row[1])
  for column in ["detail", "last_sync"]:
    if column notin folderColumns:
      result.exec(sql("ALTER TABLE folder_state ADD COLUMN " & column & " TEXT"))
  var buddyColumns: seq[string] = @[]
  for row in result.rows(sql"PRAGMA table_info(buddy_state)"):
    buddyColumns.add(row[1])
  for (column, kind) in [("next_sync", "TEXT"), ("interval_minutes", "INTEGER"), ("buddy_dials", "INTEGER")]:
    if column notin buddyColumns:
      result.exec(sql("ALTER TABLE buddy_state ADD COLUMN " & column & " " & kind))
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS sync_sessions (
      id INTEGER PRIMARY KEY,
      buddy_id TEXT,
      buddy_name TEXT,
      dialed_by TEXT,
      via TEXT,
      started_at INTEGER,
      ended_at INTEGER,
      outcome TEXT,
      bytes_sent INTEGER,
      bytes_received INTEGER,
      files_sent INTEGER,
      files_received INTEGER
    )
  """)
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS sync_requests (
      buddy_id TEXT PRIMARY KEY,
      buddy_name TEXT,
      requested_at INTEGER,
      updated_at INTEGER,
      state TEXT,
      detail TEXT
    )
  """)
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS cached_buddy_addrs (
      buddy_uuid TEXT PRIMARY KEY,
      peer_id TEXT,
      addresses TEXT,
      relay_region TEXT,
      last_seen INTEGER
    )
  """)

proc getStopRequestPath*(): string =
  config.getDataDir() / "stop-request"

proc requestDaemonStop*() =
  config.ensureDataDir()
  writeFile(getStopRequestPath(), "1")

proc takeDaemonStopRequest*(): bool =
  try:
    let path = getStopRequestPath()
    if fileExists(path):
      removeFile(path)
      return true
  except OSError:
    discard
  false

proc getSyncRequestPath*(): string =
  config.getDataDir() / "sync-request"

proc requestFolderSync*(folderName: string) =
  ## Picked up by the daemon's status loop, like a stop request.
  config.ensureDataDir()
  let f = open(getSyncRequestPath(), fmAppend)
  try:
    f.writeLine(folderName)
  finally:
    f.close()

proc takeSyncRequests*(): seq[string] =
  ## The folder names asked for since the last call. The file is renamed
  ## before reading, so a request written meanwhile lands in a new file.
  let path = getSyncRequestPath()
  let taken = path & ".taken"
  try:
    if not fileExists(path):
      return @[]
    moveFile(path, taken)
    for line in readFile(taken).splitLines():
      let name = line.strip()
      if name.len > 0 and name notin result:
        result.add(name)
    removeFile(taken)
  except CatchableError:
    discard

proc formatStatusTime(t: Time): string =
  if t.toUnix() == 0: ""
  else: t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc writeRuntimeStatus*(peerId: string, addresses: seq[string], startTime: Time, running = true) =
  config.ensureDataDir()
  let db = getStateDb()
  try:
    db.exec(sql"DELETE FROM runtime_status")
    db.exec(sql"""
      INSERT INTO runtime_status (id, peer_id, addresses, running, started_at)
      VALUES (1, ?, ?, ?, ?)
    """, peerId, addresses.join(","), if running: 1 else: 0, startTime.toUnix())
  finally:
    db.close()

proc writeLiveStatus*(buddyStatuses: seq[BuddyStatus], folderStatuses: seq[SyncStatus]) =
  config.ensureDataDir()
  let db = getStateDb()
  try:
    # One transaction, so a reader never sees the tables emptied.
    db.exec(sql"BEGIN")
    db.exec(sql"DELETE FROM buddy_state")
    for b in buddyStatuses:
      db.exec(sql"""
        INSERT INTO buddy_state (id, name, state, latency_ms, last_activity, next_sync, interval_minutes, buddy_dials)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """, b.id, b.name, $b.state, b.latencyMs, formatStatusTime(b.lastSync), formatStatusTime(b.nextSync),
        b.intervalMinutes, if b.buddyDials: 1 else: 0)
    
    db.exec(sql"DELETE FROM folder_state")
    for f in folderStatuses:
      db.exec(sql"""
        INSERT INTO folder_state (name, total_bytes, synced_bytes, file_count, synced_files, status, detail, last_sync)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """, f.folder, f.totalBytes, f.syncedBytes, f.fileCount, f.syncedFiles, f.status, f.detail, formatStatusTime(f.lastSync))
    db.exec(sql"COMMIT")
  finally:
    db.close()

proc writeSessions*(sessions: seq[SessionRecord]) =
  config.ensureDataDir()
  let db = getStateDb()
  try:
    db.exec(sql"BEGIN")
    db.exec(sql"DELETE FROM sync_sessions")
    for r in sessions:
      db.exec(sql"""
        INSERT INTO sync_sessions (id, buddy_id, buddy_name, dialed_by, via, started_at, ended_at,
          outcome, bytes_sent, bytes_received, files_sent, files_received)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, r.id, r.buddyId, r.buddyName, r.dialedBy, r.via, r.startedAt.toUnix(), r.endedAt.toUnix(),
        r.outcome, r.bytesSent, r.bytesReceived, r.filesSent, r.filesReceived)
    db.exec(sql"COMMIT")
  finally:
    db.close()

proc writeSyncRequests*(requests: seq[SyncRequestState]) =
  config.ensureDataDir()
  let db = getStateDb()
  try:
    db.exec(sql"BEGIN")
    db.exec(sql"DELETE FROM sync_requests")
    for r in requests:
      db.exec(sql"""
        INSERT INTO sync_requests (buddy_id, buddy_name, requested_at, updated_at, state, detail)
        VALUES (?, ?, ?, ?, ?, ?)
      """, r.buddyId, r.buddyName, r.requestedAt.toUnix(), r.updatedAt.toUnix(), r.state, r.detail)
    db.exec(sql"COMMIT")
  finally:
    db.close()

proc readSyncRequests*(): seq[SyncRequestState] =
  let statePath = config.getDataDir() / "state.db"
  if not fileExists(statePath):
    return @[]
  let db = getStateDb()
  try:
    for row in db.rows(sql"SELECT buddy_id, buddy_name, requested_at, updated_at, state, detail FROM sync_requests ORDER BY requested_at DESC"):
      result.add(SyncRequestState(
        buddyId: row[0],
        buddyName: row[1],
        requestedAt: fromUnix(row[2].parseBiggestInt()),
        updatedAt: fromUnix(row[3].parseBiggestInt()),
        state: row[4],
        detail: row[5],
      ))
  finally:
    db.close()

proc readSessions*(): seq[SessionRecord] =
  ## Oldest first.
  let statePath = config.getDataDir() / "state.db"
  if not fileExists(statePath):
    return @[]
  let db = getStateDb()
  try:
    for row in db.rows(sql"""
      SELECT id, buddy_id, buddy_name, dialed_by, via, started_at, ended_at, outcome,
        bytes_sent, bytes_received, files_sent, files_received
      FROM sync_sessions ORDER BY id
    """):
      result.add(SessionRecord(
        id: row[0].parseInt(),
        buddyId: row[1],
        buddyName: row[2],
        dialedBy: row[3],
        via: row[4],
        startedAt: fromUnix(row[5].parseBiggestInt()),
        endedAt: fromUnix(row[6].parseBiggestInt()),
        outcome: row[7],
        bytesSent: row[8].parseBiggestInt(),
        bytesReceived: row[9].parseBiggestInt(),
        filesSent: row[10].parseInt(),
        filesReceived: row[11].parseInt(),
      ))
  finally:
    db.close()

proc sessionsJson(): JsonNode =
  var entries: seq[JsonNode] = @[]
  let sessions = readSessions()
  for i in countdown(sessions.high, 0):
    let r = sessions[i]
    entries.add(%*{
      "id": r.id,
      "buddyId": r.buddyId,
      "buddyName": r.buddyName,
      "dialedBy": r.dialedBy,
      "via": r.via,
      "startedAt": formatStatusTime(r.startedAt),
      "endedAt": if r.outcome == "running": "" else: formatStatusTime(r.endedAt),
      "outcome": r.outcome,
      "bytesSent": r.bytesSent,
      "bytesReceived": r.bytesReceived,
      "filesSent": r.filesSent,
      "filesReceived": r.filesReceived,
    })
  var requests: seq[JsonNode] = @[]
  for r in readSyncRequests():
    requests.add(%*{
      "buddyId": r.buddyId,
      "buddyName": r.buddyName,
      "requestedAt": formatStatusTime(r.requestedAt),
      "updatedAt": formatStatusTime(r.updatedAt),
      "state": r.state,
      "detail": r.detail,
    })
  %*{"sessions": entries, "requests": requests}

type CachedBuddyAddr* = object
  peerId*: string
  addresses*: seq[string]
  relayRegion*: string
  lastSeen*: int64

proc writeCachedBuddyAddr*(buddyUuid: string, peerId: string, addresses: seq[string], relayRegion: string) =
  config.ensureDataDir()
  let db = getStateDb()
  try:
    db.exec(sql"""
      INSERT OR REPLACE INTO cached_buddy_addrs (buddy_uuid, peer_id, addresses, relay_region, last_seen)
      VALUES (?, ?, ?, ?, ?)
    """, buddyUuid, peerId, addresses.join(","), relayRegion, getTime().toUnix())
  finally:
    db.close()

proc readCachedBuddyAddr*(buddyUuid: string): Option[CachedBuddyAddr] =
  config.ensureDataDir()
  let db = getStateDb()
  try:
    let rows = db.getAllRows(sql"SELECT peer_id, addresses, relay_region, last_seen FROM cached_buddy_addrs WHERE buddy_uuid = ?", buddyUuid)
    for row in rows:
      var cachedAddr = CachedBuddyAddr()
      cachedAddr.peerId = row[0]
      cachedAddr.addresses = if row[1].len > 0: row[1].split(",") else: @[]
      cachedAddr.relayRegion = row[2]
      try:
        cachedAddr.lastSeen = parseInt(row[3])
      except ValueError:
        cachedAddr.lastSeen = 0
      return some(cachedAddr)
    return none(CachedBuddyAddr)
  finally:
    db.close()

proc markControlStopped*() =
  if not config.configExists():
    return
  writeRuntimeStatus("", @[], getTime(), running = false)

proc jsonResponse(status: int, node: JsonNode): string =
  let body = $node
  let statusText = case status
  of 200: "OK"
  of 400: "Bad Request"
  of 404: "Not Found"
  of 500: "Internal Server Error"
  else: "OK"
  result = "HTTP/1.1 " & $status & " " & statusText & "\r\n"
  result.add("Content-Type: application/json\r\n")
  result.add("Content-Length: " & $body.len & "\r\n")
  result.add("Connection: close\r\n\r\n")
  result.add(body)

proc parseRequest*(raw: string): tuple[httpMethod: string, path: string, body: string] =
  let parts = raw.split("\r\n\r\n", 1)
  let head = parts[0].splitLines()
  if head.len == 0:
    return
  let requestLine = head[0].split(" ")
  if requestLine.len >= 2:
    result.httpMethod = requestLine[0]
    result.path = decodeUrl(requestLine[1], decodePlus = false)
  if parts.len > 1:
    result.body = parts[1]

proc buildJson*(): JsonNode =
  ## The build of this process, which serves the API inside the daemon.
  %*{
    "version": BuddyDriveVersion,
    "commit": BuildCommit,
    "builtAt": BuildTime,
    "protocolVersion": int(ProtocolVersion)
  }

proc statusJson(): JsonNode =
  let statePath = config.getDataDir() / "state.db"
  if fileExists(statePath):
    let db = getStateDb()
    try:
      let row = db.getRow(sql"SELECT peer_id, addresses, running, started_at FROM runtime_status WHERE id = 1")
      if row.len > 0 and row[0].len > 0:
        let peerId = row[0]
        let addresses = if row[1].len > 0: row[1].split(",") else: @[]
        let running = row[2] == "1"
        let startedAt = row[3].parseInt()
        let uptime = if running: max(0, getTime().toUnix() - startedAt) else: 0
        
        let cfg = config.loadConfig()
        return %*{
          "buddy": {
            "name": cfg.buddy.name,
            "id": cfg.buddy.uuid
          },
          "running": running,
          "uptime": uptime,
          "peerId": peerId,
          "addresses": addresses,
          "syncEnabled": true,
          "syncWindow": "per-buddy",
          "build": buildJson()
        }
    finally:
      db.close()
  
  if config.configExists():
    let cfg = config.loadConfig()
    return %*{
      "buddy": {
        "name": cfg.buddy.name,
        "id": cfg.buddy.uuid
      },
      "running": false,
      "uptime": 0,
      "peerId": "",
      "addresses": [],
      "syncEnabled": true,
      "syncWindow": "per-buddy",
      "build": buildJson()
    }
  %*{
    "buddy": {"name": "Unknown", "id": ""},
    "running": false,
    "uptime": 0,
    "peerId": "",
    "addresses": []
  }

proc buddyScheduleJson(buddy: BuddyInfo): JsonNode =
  %*{
    "syncWindow": buddy.syncWindow,
    "syncInterval": buddy.syncInterval,
    "syncIntervalText": syncIntervalDescription(buddy.syncInterval)
  }

proc buddiesJson(): JsonNode =
  var configured = initTable[string, BuddyInfo]()
  if config.configExists():
    for buddy in config.loadConfig().buddies:
      configured[buddy.id.uuid] = buddy
  let statePath = config.getDataDir() / "state.db"
  if fileExists(statePath):
    let db = getStateDb()
    try:
      var buddies: seq[JsonNode] = @[]
      for row in db.rows(sql"SELECT id, name, state, latency_ms, last_activity, next_sync, interval_minutes, buddy_dials FROM buddy_state"):
        var entry = %*{
          "id": row[0],
          "name": row[1],
          "state": row[2],
          "latencyMs": row[3].parseInt(),
          "lastSync": row[4],
          "nextSync": row[5],
          "intervalMinutes": (if row[6].len > 0: row[6].parseInt() else: 0),
          "buddyDials": row[7] == "1"
        }
        if row[0] in configured:
          let buddy = configured[row[0]]
          entry["name"] = %buddy.id.name
          for key, value in buddyScheduleJson(buddy):
            entry[key] = value
        buddies.add(entry)
      if buddies.len > 0:
        return %*{"buddies": buddies}
    finally:
      db.close()
  
  if not config.configExists():
    return %*{"buddies": []}
  let cfg = config.loadConfig()
  var buddies: seq[JsonNode] = @[]
  for buddy in cfg.buddies:
    var entry = %*{
      "id": buddy.id.uuid,
      "name": buddy.id.name,
      "pairingCode": buddy.pairingCode,
      "state": "disconnected",
      "latencyMs": -1,
      "lastSync": ""
    }
    for key, value in buddyScheduleJson(buddy):
      entry[key] = value
    buddies.add(entry)
  %*{"buddies": buddies}

proc storageUsage(root: string): tuple[files: int, bytes: int64] =
  if not dirExists(root):
    return
  for path in walkDirRec(root, relative = false):
    if path.endsWith(".buddytmp"):
      continue
    if path.endsWith(".meta"):
      inc result.files
      continue
    try:
      result.bytes += getFileSize(path)
    except CatchableError:
      discard
    if not path.endsWith(".blob"):
      inc result.files

proc cachedStorageUsage(root: string): tuple[files: int, bytes: int64] =
  let now = getTime()
  if root in storageUsageCache:
    let cached = storageUsageCache[root]
    if now - cached.at < storageUsageMaxAge:
      return (cached.files, cached.bytes)
  result = storageUsage(root)
  storageUsageCache[root] = (result.files, result.bytes, now)

proc storageJson(): JsonNode =
  if not config.configExists():
    return %*{"storage": []}
  let cfg = config.loadConfig()
  var entries: seq[JsonNode] = @[]
  for buddy in cfg.buddies:
    let root = cfg.buddyStorageRoot(buddy.id.uuid)
    let usage = cachedStorageUsage(root)
    entries.add(%*{
      "buddyId": buddy.id.uuid,
      "buddyName": buddy.id.name,
      "path": root,
      "files": usage.files,
      "bytes": usage.bytes,
    })
  %*{"storage": entries}

proc foldersJson(): JsonNode =
  var liveFolders: Table[string, JsonNode] = initTable[string, JsonNode]()
  
  let statePath = config.getDataDir() / "state.db"
  if fileExists(statePath):
    let db = getStateDb()
    try:
      for row in db.rows(sql"SELECT name, total_bytes, synced_bytes, file_count, synced_files, status, detail, last_sync FROM folder_state"):
        liveFolders[row[0]] = %*{
          "totalBytes": row[1].parseInt(),
          "syncedBytes": row[2].parseInt(),
          "fileCount": row[3].parseInt(),
          "syncedFiles": row[4].parseInt(),
          "status": row[5],
          "detail": row[6],
          "lastSync": row[7]
        }
    finally:
      db.close()
  
  if not config.configExists():
    return %*{"folders": []}
  let cfg = config.loadConfig()
  var folders: seq[JsonNode] = @[]
  for folder in cfg.folders:
    var folderJson = %*{
      "id": folder.id,
      "name": folder.name,
      "path": folder.path,
      "encrypted": folder.encrypted,
      "appendOnly": folder.appendOnly,
      "buddies": folder.buddies,
      "status": {
        "totalBytes": 0,
        "syncedBytes": 0,
        "fileCount": 0,
        "syncedFiles": 0,
        "status": "idle",
        "detail": "",
        "lastSync": ""
      }
    }
    if liveFolders.hasKey(folder.name):
      folderJson["status"] = liveFolders[folder.name]
    folders.add(folderJson)
  %*{"folders": folders}

proc configJson(): JsonNode =
  if not config.configExists():
    return %*{"buddy": {}, "folders": [], "buddies": []}
  let cfg = config.loadConfig()
  var folders: seq[JsonNode] = @[]
  var buddies: seq[JsonNode] = @[]
  for folder in cfg.folders:
    folders.add(%*{
      "name": folder.name,
      "path": folder.path,
      "encrypted": folder.encrypted,
      "append_only": folder.appendOnly,
      "buddies": folder.buddies
    })
  for buddy in cfg.buddies:
    buddies.add(%*{
      "id": buddy.id.uuid,
      "name": buddy.id.name,
      "pairing_code": buddy.pairingCode,
      "sync_window": buddy.syncWindow,
      "sync_interval": buddy.syncInterval,
      "addedAt": buddy.addedAt.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    })
  %*{
    "buddy": {
      "name": cfg.buddy.name,
      "id": cfg.buddy.uuid
    },
    "network": {
      "listen_port": cfg.listenPort,
      "announce_addr": cfg.announceAddr,
      "api_base_url": cfg.apiBaseUrl,
      "relay_region": cfg.relayRegion,
      "storage_base_path": cfg.storageBasePath,
      "bandwidth_limit_kbps": cfg.bandwidthLimitKBps
    },
    "gui": {
      "locale": cfg.guiLocale
    },
    "folders": folders,
    "buddies": buddies
  }

proc logsJson(): JsonNode =
  let logPath = config.getLogPath()
  if not fileExists(logPath):
    return %*{"logs": []}
  let lines = readFile(logPath).splitLines()
  let start = max(0, lines.len - 100)
  var logs: seq[JsonNode] = @[]
  for i in start ..< lines.len:
    if lines[i].len > 0:
      logs.add(%*{"raw": lines[i]})
  %*{"logs": logs}

proc pairingCodeJson(): JsonNode =
  let code = generatePairingCode()
  let cfg = config.loadConfig()
  %*{
    "buddyId": cfg.buddy.uuid,
    "buddyName": cfg.buddy.name,
    "pairingCode": code
  }

proc addFolderFromBody(body: string): tuple[status: int, response: JsonNode] =
  let parsed = parseJson(body)
  var cfg = config.loadConfig()
  var folder = newSyncFolder(parsed{"name"}.getStr(""), parsed{"path"}.getStr(""), parsed{"encrypted"}.getBool(true))
  if folder.name.len == 0 or folder.path.len == 0:
    return (400, %*{"error": "name and path are required", "code": "INVALID_REQUEST"})
  if cfg.getFolder(folder.name) >= 0:
    return (409, %*{"error": "A folder with that name already exists", "code": "FOLDER_EXISTS"})
  folder.appendOnly = parsed{"appendOnly"}.getBool(parsed{"append_only"}.getBool(false))
  if parsed.hasKey("buddies"):
    for item in parsed["buddies"]:
      folder.buddies.add(item.getStr())
  cfg.addFolder(folder)
  (200, %*{"ok": true})

proc updateFolderFromBody(body: string): tuple[status: int, response: JsonNode] =
  ## Changes a folder's name, path, sharing or append-only flag. Encryption is
  ## left alone: switching it would orphan what the buddy already stores.
  let parsed = parseJson(body)
  let folderId = parsed{"id"}.getStr("")
  var cfg = config.loadConfig()
  var idx = -1
  for i, folder in cfg.folders:
    if folderId.len > 0 and folder.id == folderId:
      idx = i
  if idx < 0:
    return (404, %*{"error": "Folder not found", "code": "FOLDER_NOT_FOUND"})

  let name = parsed{"name"}.getStr(cfg.folders[idx].name)
  let path = parsed{"path"}.getStr(cfg.folders[idx].path)
  if name.len == 0 or path.len == 0:
    return (400, %*{"error": "name and path are required", "code": "INVALID_REQUEST"})
  for i, folder in cfg.folders:
    if i != idx and folder.name == name:
      return (409, %*{"error": "A folder with that name already exists", "code": "FOLDER_EXISTS"})

  cfg.folders[idx].name = name
  cfg.folders[idx].path = path
  if parsed.hasKey("appendOnly"):
    cfg.folders[idx].appendOnly = parsed["appendOnly"].getBool(false)
  if parsed.hasKey("buddies"):
    cfg.folders[idx].buddies = @[]
    for item in parsed["buddies"]:
      cfg.folders[idx].buddies.add(item.getStr())
  config.saveConfig(cfg)
  (200, %*{"ok": true})

proc removeFolderByName(name: string): tuple[status: int, response: JsonNode] =
  var cfg = config.loadConfig()
  if not cfg.removeFolder(name):
    return (404, %*{"error": "Folder not found", "code": "FOLDER_NOT_FOUND"})
  (200, %*{"ok": true})

proc removeBuddyById(uuid: string): tuple[status: int, response: JsonNode] =
  var cfg = config.loadConfig()
  if not cfg.removeBuddy(uuid):
    return (404, %*{"error": "Buddy not found", "code": "BUDDY_NOT_FOUND"})
  (200, %*{"ok": true})

proc isLocaleTag*(value: string): bool =
  ## A loose BCP 47 check: the browser decides whether it knows the tag.
  if value.len == 0:
    return true
  if value.len > 35:
    return false
  for part in value.split('-'):
    if part.len == 0 or part.len > 8:
      return false
    for c in part:
      if not c.isAlphaNumeric():
        return false
  value[0].isAlphaAscii()

proc updateConfigFromBody(body: string): tuple[status: int, response: JsonNode] =
  let parsed = parseJson(body)
  let oldCfg = config.loadConfig()
  var cfg = oldCfg

  if parsed.hasKey("buddy"):
    let buddy = parsed["buddy"]
    if buddy.hasKey("name"):
      cfg.buddy.name = buddy["name"].getStr(cfg.buddy.name)

  if parsed.hasKey("gui") and parsed["gui"].hasKey("locale"):
    let locale = parsed["gui"]["locale"].getStr("").strip()
    if not isLocaleTag(locale):
      return (400, %*{"error": "Locale must be a language tag such as sv-SE, or empty for the browser's", "code": "INVALID_LOCALE"})
    cfg.guiLocale = locale

  if parsed.hasKey("network"):
    let net = parsed["network"]
    if net.hasKey("listen_port"):
      cfg.listenPort = net["listen_port"].getInt(cfg.listenPort)
    if net.hasKey("announce_addr"):
      cfg.announceAddr = net["announce_addr"].getStr(cfg.announceAddr)
    if net.hasKey("api_base_url"):
      cfg.apiBaseUrl = net["api_base_url"].getStr(cfg.apiBaseUrl)
    if net.hasKey("relay_region"):
      cfg.relayRegion = net["relay_region"].getStr(cfg.relayRegion)
    if net.hasKey("storage_base_path"):
      cfg.storageBasePath = net["storage_base_path"].getStr(cfg.storageBasePath)
    if net.hasKey("bandwidth_limit_kbps"):
      cfg.bandwidthLimitKBps = net["bandwidth_limit_kbps"].getInt(cfg.bandwidthLimitKBps)

  if parsed.hasKey("folders"):
    cfg.folders = @[]
    for item in parsed["folders"].getElems():
      var folder = newSyncFolder(
        item{"name"}.getStr(""),
        item{"path"}.getStr(""),
        item{"encrypted"}.getBool(true)
      )
      # An existing folder keeps its id and key; replacing the key would make
      # its backup unreadable.
      let itemId = item{"id"}.getStr("")
      for existing in oldCfg.folders:
        if (itemId.len > 0 and existing.id == itemId) or (itemId.len == 0 and existing.name == folder.name):
          folder.id = existing.id
          folder.folderKey = existing.folderKey
          break
      folder.appendOnly = item{"append_only"}.getBool(false)
      if item.hasKey("buddies"):
        for buddyId in item["buddies"].getElems():
          folder.buddies.add(buddyId.getStr())
      if folder.name.len > 0 and folder.path.len > 0:
        cfg.folders.add(folder)

  if parsed.hasKey("buddies"):
    cfg.buddies = @[]
    for item in parsed["buddies"].getElems():
      let buddyId = item{"id"}.getStr("")
      if buddyId.len == 0:
        continue
      var buddy: BuddyInfo
      buddy.id = newBuddyId(buddyId, item{"name"}.getStr(""))
      buddy.pairingCode = item{"pairing_code"}.getStr("")
      buddy.syncWindow = item{"sync_window"}.getStr(item{"sync_time"}.getStr(""))
      buddy.syncInterval = item{"sync_interval"}.getStr("")
      buddy.addedAt = getTime()
      for oldBuddy in oldCfg.buddies:
        if oldBuddy.id.uuid == buddyId:
          buddy.addedAt = oldBuddy.addedAt
          buddy.storagePath = oldBuddy.storagePath
          buddy.addresses = oldBuddy.addresses
          break
      if item.hasKey("addedAt"):
        try:
          buddy.addedAt = parseTime(item["addedAt"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
        except ValueError:
          discard
      cfg.buddies.add(buddy)

  config.saveConfig(cfg)

  let restartRequired =
    cfg.buddy.name != oldCfg.buddy.name or
    cfg.listenPort != oldCfg.listenPort or
    cfg.announceAddr != oldCfg.announceAddr or
    cfg.apiBaseUrl != oldCfg.apiBaseUrl or
    cfg.relayRegion != oldCfg.relayRegion or
    cfg.storageBasePath != oldCfg.storageBasePath or
    cfg.bandwidthLimitKBps != oldCfg.bandwidthLimitKBps

  (200, %*{"ok": true, "restartRequired": restartRequired})

proc readSchedule(parsed: JsonNode, buddy: var BuddyInfo): string =
  ## Applies sync_window / sync_interval from a request; the error, if any.
  if parsed.hasKey("sync_window") or parsed.hasKey("sync_time"):
    let window = parsed{"sync_window"}.getStr(parsed{"sync_time"}.getStr("")).strip()
    if not isValidSyncWindow(window):
      return "Sync window must look like 22:00-06:00, or be empty for any time"
    buddy.syncWindow = window
  if parsed.hasKey("sync_interval"):
    let interval = parsed{"sync_interval"}.getStr("").strip()
    if not isValidSyncInterval(interval):
      return "Sync interval must look like 30m, 2h or 1h30m, or be empty for the default"
    buddy.syncInterval = interval
  ""

proc pairBuddyFromBody(body: string): tuple[status: int, response: JsonNode] =
  let parsed = parseJson(body)
  let buddyId = parsed{"buddyId"}.getStr("").strip()
  let buddyName = parsed{"buddyName"}.getStr("").strip()
  let code = parsed{"code"}.getStr("").strip()
  
  if buddyId.len == 0 or code.len == 0:
    return (400, %*{"error": "buddyId and code are required", "code": "INVALID_REQUEST"})
  if buddyName.len == 0:
    return (400, %*{"error": "A name for the buddy is required", "code": "INVALID_REQUEST"})
  
  var cfg = config.loadConfig()
  if buddyId == cfg.buddy.uuid:
    return (400, %*{"error": "That is your own Buddy ID; enter your buddy's", "code": "INVALID_REQUEST"})
  var buddy: BuddyInfo
  let idx = cfg.getBuddy(buddyId)
  if idx >= 0:
    buddy = cfg.buddies[idx]
  else:
    buddy.id.uuid = buddyId
    buddy.addedAt = getTime()
  buddy.id.name = buddyName
  buddy.pairingCode = code
  let error = readSchedule(parsed, buddy)
  if error.len > 0:
    return (400, %*{"error": error, "code": "INVALID_SCHEDULE"})
  cfg.addBuddy(buddy)
  (200, %*{"ok": true, "message": "Buddy paired successfully"})

proc updateBuddyFromBody(body: string): tuple[status: int, response: JsonNode] =
  ## Changes a buddy's name and when we sync with it.
  let parsed = parseJson(body)
  var cfg = config.loadConfig()
  let idx = cfg.getBuddy(parsed{"id"}.getStr(""))
  if idx < 0:
    return (404, %*{"error": "Buddy not found", "code": "BUDDY_NOT_FOUND"})
  var buddy = cfg.buddies[idx]
  if parsed.hasKey("name"):
    let name = parsed["name"].getStr("").strip()
    if name.len == 0:
      return (400, %*{"error": "A name for the buddy is required", "code": "INVALID_REQUEST"})
    buddy.id.name = name
  let error = readSchedule(parsed, buddy)
  if error.len > 0:
    return (400, %*{"error": error, "code": "INVALID_SCHEDULE"})
  cfg.buddies[idx] = buddy
  config.saveConfig(cfg)
  (200, %*{"ok": true})

proc setupRecoveryHandler(): tuple[status: int, response: JsonNode] =
  if not config.configExists():
    return (400, %*{"error": "No config found. Run init first.", "code": "NO_CONFIG"})
  
  var cfg = config.loadConfig()
  if cfg.recovery.enabled:
    return (400, %*{"error": "Recovery already enabled", "code": "ALREADY_SETUP"})
  
  let (mnemonic, recovery) = setupRecovery()
  cfg.recovery = recovery
  config.saveConfig(cfg)
  
  let words = mnemonic.splitWhitespace()
  pendingRecoveryWords = words
  (200, %*{
    "ok": true,
    "mnemonic": mnemonic,
    "words": words,
    "publicKey": recovery.publicKeyB58,
    "masterKey": recovery.masterKey
  })

proc verifyRecoveryWordHandler(body: string): tuple[status: int, response: JsonNode] =
  if not config.configExists():
    return (400, %*{"error": "No config found", "code": "NO_CONFIG"})
  
  let cfg = config.loadConfig()
  if not cfg.recovery.enabled:
    return (400, %*{"error": "Recovery not set up", "code": "NOT_SETUP"})
  
  let parsed = parseJson(body)
  let index = parsed{"index"}.getInt(-1)
  let word = parsed{"word"}.getStr("")
  
  if index < 0 or index >= 12:
    return (400, %*{"error": "index must be 0-11", "code": "INVALID_INDEX"})
  if word.len == 0:
    return (400, %*{"error": "word is required", "code": "MISSING_WORD"})
  if pendingRecoveryWords.len != 12:
    return (400, %*{"error": "No pending recovery setup", "code": "NO_PENDING_SETUP"})
  
  let expected = pendingRecoveryWords[index].toLowerAscii()
  let correct = word.toLowerAscii() == expected.toLowerAscii()
  
  (200, %*{"ok": true, "correct": correct})

proc recoverHandler(body: string): tuple[status: int, response: JsonNode] =
  let parsed = parseJson(body)
  let mnemonic = parsed{"mnemonic"}.getStr("")
  
  if mnemonic.splitWhitespace().len != 12:
    return (400, %*{"error": "Must provide 12-word mnemonic", "code": "INVALID_MNEMONIC"})
  
  if not validateMnemonic(mnemonic):
    return (400, %*{"error": "Invalid mnemonic words", "code": "INVALID_MNEMONIC"})
  
  let recovery = recoverFromMnemonic(mnemonic)
  
  if not config.configExists():
    return (400, %*{"error": "No config file to verify against", "code": "NO_CONFIG"})
  
  let cfg = config.loadConfig()
  if not verifyMnemonic(mnemonic, cfg.recovery.masterKey):
    return (400, %*{"error": "Mnemonic does not match stored master key", "code": "MISMATCH"})
  
  (200, %*{
    "ok": true,
    "publicKey": recovery.publicKeyB58,
    "masterKey": recovery.masterKey
  })

proc exportRecoveryHandler(): tuple[status: int, response: JsonNode] =
  if not config.configExists():
    return (400, %*{"error": "No config found", "code": "NO_CONFIG"})
  
  let cfg = config.loadConfig()
  if not cfg.recovery.enabled:
    return (400, %*{"error": "Recovery not set up", "code": "NOT_SETUP"})
  
  (200, %*{
    "ok": true,
    "publicKey": cfg.recovery.publicKeyB58,
    "masterKey": cfg.recovery.masterKey,
    "enabled": cfg.recovery.enabled
  })

proc daemonRunning(): bool =
  let statePath = config.getDataDir() / "state.db"
  if not fileExists(statePath):
    return false
  let db = getStateDb()
  try:
    db.getValue(sql"SELECT running FROM runtime_status WHERE id = 1") == "1"
  finally:
    db.close()

proc requestSyncFor(cfg: AppConfig, folders: seq[FolderConfig]): JsonNode =
  ## Which buddies the daemon will dial for these folders.
  var buddies: seq[JsonNode] = @[]
  var seen: seq[string] = @[]
  for folder in folders:
    requestFolderSync(folder.name)
    for buddy in cfg.buddies:
      if folderAppliesToBuddy(folder, buddy.id.uuid) and buddy.id.uuid notin seen:
        seen.add(buddy.id.uuid)
        buddies.add(%*{"id": buddy.id.uuid, "name": buddy.id.name})
  %*{
    "ok": true,
    "message": "Sync requested",
    "folders": folders.len,
    "buddies": buddies,
    "daemonRunning": daemonRunning()
  }

proc syncFolderByName(name: string): tuple[status: int, response: JsonNode] =
  if not config.configExists():
    return (404, %*{"error": "Folder not found", "code": "NOT_FOUND"})
  let cfg = config.loadConfig()
  for folder in cfg.folders:
    if folder.name == name:
      var response = requestSyncFor(cfg, @[folder])
      response["folder"] = %name
      return (200, response)
  (404, %*{"error": "Folder not found", "code": "NOT_FOUND"})

proc syncAllFolders(): tuple[status: int, response: JsonNode] =
  if not config.configExists():
    return (400, %*{"error": "No config found", "code": "NO_CONFIG"})
  let cfg = config.loadConfig()
  (200, requestSyncFor(cfg, cfg.folders))

proc syncConfigHandler(): tuple[status: int, response: JsonNode] =
  if not config.configExists():
    return (400, %*{"error": "No config found", "code": "NO_CONFIG"})
  
  let cfg = config.loadConfig()
  if not cfg.recovery.enabled:
    return (400, %*{"error": "Recovery not set up", "code": "NOT_SETUP"})
  
  let relayUrl = if cfg.apiBaseUrl.len > 0: cfg.apiBaseUrl else: DefaultKvApiUrl
  let synced = waitFor syncConfigToRelay(cfg, relayUrl)
  
  if synced:
    (200, %*{"ok": true, "message": "Config synced to relay"})
  else:
    (500, %*{"error": "Failed to sync config to relay", "code": "SYNC_FAILED"})

proc handleRequest*(raw: string): string =
  let webResponse = serveWebRequest(raw)
  if webResponse.len > 0:
    return webResponse
  let req = parseRequest(raw)
  try:
    case req.httpMethod
    of "GET":
      case req.path
      of "/status": jsonResponse(200, statusJson())
      of "/buddies": jsonResponse(200, buddiesJson())
      of "/folders": jsonResponse(200, foldersJson())
      of "/storage": jsonResponse(200, storageJson())
      of "/sessions": jsonResponse(200, sessionsJson())
      of "/config": jsonResponse(200, configJson())
      of "/logs": jsonResponse(200, logsJson())
      of "/recovery":
        let resp = exportRecoveryHandler()
        jsonResponse(resp.status, resp.response)
      else: jsonResponse(404, %*{"error": "Not found", "code": "NOT_FOUND"})
    of "POST":
      case req.path
      of "/buddies/pairing-code": jsonResponse(200, pairingCodeJson())
      of "/buddies/pair":
        let resp = pairBuddyFromBody(req.body)
        jsonResponse(resp.status, resp.response)
      of "/buddies/update":
        let resp = updateBuddyFromBody(req.body)
        jsonResponse(resp.status, resp.response)
      of "/sync":
        let resp = syncAllFolders()
        jsonResponse(resp.status, resp.response)
      of "/config":
        let resp = updateConfigFromBody(req.body)
        jsonResponse(resp.status, resp.response)
      of "/config/reload":
        discard config.loadConfig()
        jsonResponse(200, %*{"ok": true})
      of "/folders/update":
        let resp = updateFolderFromBody(req.body)
        jsonResponse(resp.status, resp.response)
      of "/folders":
        let resp = addFolderFromBody(req.body)
        jsonResponse(resp.status, resp.response)
      of "/recovery/setup":
        let resp = setupRecoveryHandler()
        jsonResponse(resp.status, resp.response)
      of "/recovery/verify-word":
        let resp = verifyRecoveryWordHandler(req.body)
        jsonResponse(resp.status, resp.response)
      of "/recovery/recover":
        let resp = recoverHandler(req.body)
        jsonResponse(resp.status, resp.response)
      of "/recovery/export":
        let resp = exportRecoveryHandler()
        jsonResponse(resp.status, resp.response)
      of "/recovery/sync-config":
        let resp = syncConfigHandler()
        jsonResponse(resp.status, resp.response)
      of "/daemon/stop":
        requestDaemonStop()
        jsonResponse(200, %*{"ok": true, "message": "Daemon stop requested"})
      else:
        if req.path.startsWith("/sync/"):
          let resp = syncFolderByName(req.path[6 .. ^1])
          jsonResponse(resp.status, resp.response)
        else:
          jsonResponse(404, %*{"error": "Not found", "code": "NOT_FOUND"})
    of "DELETE":
      if req.path.startsWith("/folders/"):
        let resp = removeFolderByName(req.path[9 .. ^1])
        jsonResponse(resp.status, resp.response)
      elif req.path.startsWith("/buddies/"):
        let resp = removeBuddyById(req.path[9 .. ^1])
        jsonResponse(resp.status, resp.response)
      else:
        jsonResponse(404, %*{"error": "Not found", "code": "NOT_FOUND"})
    else:
      jsonResponse(400, %*{"error": "Unsupported method", "code": "BAD_METHOD"})
  except CatchableError as e:
    jsonResponse(500, %*{"error": e.msg, "code": "INTERNAL_ERROR"})

proc controlServerMain(port: int) {.thread.} =
  let socket = newSocket(buffered = false)
  socket.setSockOpt(OptReuseAddr, true)
  socket.bindAddr(Port(port), "0.0.0.0")
  socket.listen()
  echo "Control server started on port ", port
  while true:
    var client: owned(Socket)
    socket.accept(client)
    try:
      let (address, _) = client.getPeerAddr()
      let raw = client.recv(64 * 1024)
      if raw.len > 0:
        let response = block:
          {.cast(gcsafe).}:
            if isLocalhost(address):
              handleRequest(raw)
            else:
              if not config.configExists():
                forbiddenResponse
              else:
                let uuid = config.loadConfig().buddy.uuid
                let redirect = lanRootRedirect(raw, uuid)
                let rewritten = rewriteLanRequest(raw, uuid)
                if redirect.len > 0:
                  redirect
                elif rewritten.len == 0:
                  forbiddenResponse
                else:
                  handleRequest(rewritten)
        client.send(response)
    except CatchableError:
      discard
    finally:
      client.close()

proc webGuiUrls*(port: int, buddyUuid: string, lanHosts: seq[string]): seq[string] =
  result.add("http://127.0.0.1:" & $port & "/")
  let secret = webSecret(buddyUuid)
  for host in (if lanHosts.len > 0: lanHosts else: @["<your-ip>"]):
    result.add("http://" & host & ":" & $port & "/w/" & secret & "/")

proc startControlServer*(port: int = DefaultControlPort, lanHosts: seq[string] = @[]) =
  if controlStarted:
    return
  config.ensureDataDir()
  writeFile(config.getDataDir() / "port", $port)
  controlStarted = true
  createThread(controlThread, controlServerMain, port)
  try:
    if config.configExists():
      let urls = webGuiUrls(port, config.loadConfig().buddy.uuid, lanHosts)
      echo "Web GUI (localhost): ", urls[0]
      for url in urls[1 .. ^1]:
        echo "Web GUI (LAN): ", url
  except Exception as e:
    echo "Could not read the config to show the web GUI address: ", e.msg

proc stopControlServer*() =
  markControlStopped()
  let portPath = config.getDataDir() / "port"
  if fileExists(portPath):
    removeFile(portPath)
