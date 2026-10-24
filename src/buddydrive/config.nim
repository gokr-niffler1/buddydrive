import std/base64
import std/os
import std/times
import std/strutils
import std/sequtils
import parsetoml
import uuids
import types
import crypto
import logutils

export newAppConfig
export newBuddyId

const CONFIG_DIR* = ".buddydrive"
const CONFIG_FILE* = "config.toml"
const STATE_FILE* = "state.db"
const INDEX_FILE* = "index.db"
const LOG_FILE* = "buddydrive.log"

proc getConfigDir*(): string =
  result = getEnv("BUDDYDRIVE_CONFIG_DIR")
  if result.len == 0:
    result = getHomeDir() / CONFIG_DIR

proc getDataDir*(): string =
  result = getEnv("BUDDYDRIVE_DATA_DIR")
  if result.len == 0:
    result = getConfigDir()

proc getConfigPath*(): string =
  result = getConfigDir() / CONFIG_FILE

proc getStatePath*(): string =
  result = getDataDir() / STATE_FILE

proc getIndexPath*(): string =
  result = getDataDir() / INDEX_FILE

proc getLogPath*(): string =
  result = getDataDir() / LOG_FILE

proc ensureDataDir*()

proc getMachineIdPath*(): string =
  getDataDir() / "machine-id"

proc machineId*(): string =
  ## Identifies this installation, as opposed to the buddy identity in
  ## config.toml, which recovery copies to a new machine. A storage buddy uses
  ## it to tell two machines claiming to be the same owner apart.
  let path = getMachineIdPath()
  if fileExists(path):
    result = readFile(path).strip()
    if result.len > 0:
      return
  ensureDataDir()
  result = $genUuid()
  writeFile(path, result & "\n")

proc getTakeoverPath*(): string =
  getDataDir() / "takeover-pending"

proc pendingTakeovers*(): seq[string] =
  ## Buddies this machine still has to claim ownership at, one per line.
  let path = getTakeoverPath()
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    if line.strip().len > 0:
      result.add(line.strip())

proc requestTakeover*(buddyIds: seq[string]) =
  ## This machine replaces the previous owner: at the next successful session
  ## with each of these buddies, it claims its folders there.
  ensureDataDir()
  writeFile(getTakeoverPath(), buddyIds.join("\n") & "\n")

proc clearTakeover*(buddyId: string) =
  let remaining = pendingTakeovers().filterIt(it != buddyId)
  if remaining.len == 0:
    try:
      removeFile(getTakeoverPath())
    except OSError:
      discard
  else:
    writeFile(getTakeoverPath(), remaining.join("\n") & "\n")

proc ensureConfigDir*() =
  let dir = getConfigDir()
  if not dir.dirExists():
    createDir(dir)

proc ensureDataDir*() =
  let dir = getDataDir()
  if not dir.dirExists():
    createDir(dir)

proc escapeToml*(s: string): string =
  result = s.replace("\\", "\\\\")
  result = result.replace("\"", "\\\"")
  result = result.replace("\n", "\\n")
  result = result.replace("\r", "\\r")
  result = result.replace("\t", "\\t")

proc encodeFolderKey(folderKey: string): string =
  if folderKey.len == 0:
    return ""
  encode(folderKey)

proc decodeFolderKey(encoded: string): string =
  if encoded.len == 0:
    return ""
  try:
    decode(encoded)
  except CatchableError:
    encoded

proc configToToml*(config: AppConfig, includeHeader = false): string =
  if includeHeader:
    result.add("# BuddyDrive Configuration\n")
    result.add("# Generated: " & now().format("yyyy-MM-dd HH:mm:ss") & "\n\n")

  result.add("[buddy]\n")
  result.add("name = \"" & escapeToml(config.buddy.name) & "\"\n")
  result.add("id = \"" & escapeToml(config.buddy.uuid) & "\"\n\n")

  if config.recovery.enabled:
    result.add("[recovery]\n")
    result.add("enabled = true\n")
    result.add("public_key = \"" & escapeToml(config.recovery.publicKeyB58) & "\"\n")
    result.add("master_key = \"" & escapeToml(config.recovery.masterKey) & "\"\n\n")

  result.add("[network]\n")
  result.add("listen_port = " & $config.listenPort & "\n")
  result.add("announce_addr = \"" & escapeToml(config.announceAddr) & "\"\n")
  result.add("api_base_url = \"" & escapeToml(config.apiBaseUrl) & "\"\n")
  result.add("relay_region = \"" & escapeToml(config.relayRegion) & "\"\n")
  result.add("storage_base_path = \"" & escapeToml(config.storageBasePath) & "\"\n")
  result.add("bandwidth_limit_kbps = " & $config.bandwidthLimitKBps & "\n\n")

  if config.guiLocale.len > 0:
    result.add("[gui]\n")
    result.add("locale = \"" & escapeToml(config.guiLocale) & "\"\n\n")

  if config.folders.len > 0:
    result.add("[[folders]]\n")
    for i, folder in config.folders:
      if i > 0:
        result.add("\n[[folders]]\n")
      if folder.id.len > 0:
        result.add("id = \"" & escapeToml(folder.id) & "\"\n")
      result.add("name = \"" & escapeToml(folder.name) & "\"\n")
      result.add("path = \"" & escapeToml(folder.path) & "\"\n")
      result.add("encrypted = " & $folder.encrypted & "\n")
      result.add("append_only = " & $folder.appendOnly & "\n")
      if folder.folderKey.len > 0:
        result.add("folder_key = \"" & escapeToml(encodeFolderKey(folder.folderKey)) & "\"\n")
      if folder.buddies.len > 0:
        result.add("buddies = [")
        for j, buddy in folder.buddies:
          if j > 0:
            result.add(", ")
          result.add("\"" & escapeToml(buddy) & "\"")
        result.add("]\n")

  if config.buddies.len > 0:
    result.add("\n[[buddies]]\n")
    for i, buddy in config.buddies:
      if i > 0:
        result.add("\n[[buddies]]\n")
      result.add("id = \"" & escapeToml(buddy.id.uuid) & "\"\n")
      result.add("name = \"" & escapeToml(buddy.id.name) & "\"\n")
      result.add("pairing_code = \"" & escapeToml(buddy.pairingCode) & "\"\n")
      if buddy.syncWindow.len > 0:
        result.add("sync_window = \"" & escapeToml(buddy.syncWindow) & "\"\n")
      if buddy.syncInterval.len > 0:
        result.add("sync_interval = \"" & escapeToml(buddy.syncInterval) & "\"\n")
      if buddy.storagePath.len > 0:
        result.add("storage_path = \"" & escapeToml(buddy.storagePath) & "\"\n")
      if buddy.addresses.len > 0:
        result.add("addresses = [" & buddy.addresses.mapIt("\"" & escapeToml(it) & "\"").join(", ") & "]\n")
      result.add("added_at = \"" & buddy.addedAt.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'") & "\"\n")

proc parseConfigToml*(toml: TomlValueRef): AppConfig =
  result.buddy.uuid = toml["buddy"]["id"].getStr()
  result.buddy.name = toml["buddy"]["name"].getStr("")
  result.recovery.enabled = false
  result.recovery.publicKeyB58 = ""
  result.recovery.masterKey = ""
  result.listenPort = DefaultP2PPort
  result.announceAddr = ""
  result.apiBaseUrl = "https://api.buddydrive.org"
  result.relayRegion = "eu"
  result.storageBasePath = ""
  result.bandwidthLimitKBps = 0

  if "recovery" in toml:
    result.recovery.enabled = toml["recovery"]{"enabled"}.getBool(false)
    result.recovery.publicKeyB58 = toml["recovery"]{"public_key"}.getStr("")
    result.recovery.masterKey = toml["recovery"]{"master_key"}.getStr("")

  if "network" in toml:
    result.listenPort = toml["network"]{"listen_port"}.getInt(DefaultP2PPort)
    result.announceAddr = toml["network"]{"announce_addr"}.getStr("")
    let parsed = toml["network"]{"api_base_url"}.getStr("")
    result.apiBaseUrl = if parsed.len > 0: parsed else: "https://api.buddydrive.org"
    result.relayRegion = toml["network"]{"relay_region"}.getStr("")
    result.storageBasePath = toml["network"]{"storage_base_path"}.getStr("")
    result.bandwidthLimitKBps = toml["network"]{"bandwidth_limit_kbps"}.getInt(0)

  if "gui" in toml:
    result.guiLocale = toml["gui"]{"locale"}.getStr("")

  result.folders = @[]
  if "folders" in toml:
    for folderTbl in toml["folders"].getElems():
      var folder: FolderConfig
      folder.id = folderTbl{"id"}.getStr("")
      folder.name = folderTbl["name"].getStr()
      folder.path = folderTbl["path"].getStr()
      folder.encrypted = folderTbl{"encrypted"}.getBool(true)
      folder.appendOnly = folderTbl{"append_only"}.getBool(false)
      folder.folderKey = decodeFolderKey(folderTbl{"folder_key"}.getStr(""))
      folder.buddies = @[]
      if "buddies" in folderTbl:
        for buddy in folderTbl["buddies"].getElems():
          folder.buddies.add(buddy.getStr())
      result.folders.add(folder)

  result.buddies = @[]
  if "buddies" in toml:
    for buddyTbl in toml["buddies"].getElems():
      var buddy: BuddyInfo
      buddy.id.uuid = buddyTbl["id"].getStr()
      buddy.id.name = buddyTbl{"name"}.getStr("")
      buddy.pairingCode = buddyTbl{"pairing_code"}.getStr("")
      buddy.syncWindow = buddyTbl{"sync_window"}.getStr(buddyTbl{"sync_time"}.getStr(""))
      buddy.syncInterval = buddyTbl{"sync_interval"}.getStr("")
      buddy.storagePath = buddyTbl{"storage_path"}.getStr("")
      buddy.addresses = @[]
      if "addresses" in buddyTbl:
        for address in buddyTbl["addresses"].getElems():
          buddy.addresses.add(address.getStr())
      buddy.addedAt = parseTime(buddyTbl{"added_at"}.getStr("1970-01-01T00:00:00Z"), "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
      result.buddies.add(buddy)

proc parseConfigString*(content: string): AppConfig =
  parseConfigToml(parseString(content))

proc loadConfig*(): AppConfig =
  let path = getConfigPath()
  if not fileExists(path):
    logError("Config file not found: " & path)
    raise newException(IOError, "Config file not found. Run 'buddydrive init' first.")

  result = parseConfigToml(parseFile(path))

proc saveConfig*(config: AppConfig) =
  ensureConfigDir()
  let path = getConfigPath()
  let tempPath = path & ".tmp"
  let content = configToToml(config, includeHeader = true)
  writeFile(tempPath, content)
  moveFile(tempPath, path)
  logInfo("Config saved to: " & path)

proc initConfig*(name: string, uuid: string): AppConfig =
  ensureConfigDir()
  result = newAppConfig(newBuddyId(uuid, name))
  saveConfig(result)
  logInfo("Initialized config at: " & getConfigPath())

proc configExists*(): bool =
  result = fileExists(getConfigPath())

proc addFolder*(config: var AppConfig, folder: FolderConfig) =
  config.folders.add(folder)
  saveConfig(config)

proc removeFolder*(config: var AppConfig, name: string): bool =
  let idx = config.folders.mapIt(it.name).find(name)
  if idx >= 0:
    config.folders.delete(idx)
    saveConfig(config)
    result = true
  else:
    result = false

proc addBuddy*(config: var AppConfig, buddy: BuddyInfo) =
  let idx = config.buddies.mapIt(it.id.uuid).find(buddy.id.uuid)
  if idx >= 0:
    config.buddies[idx] = buddy
  else:
    config.buddies.add(buddy)
  saveConfig(config)

proc removeBuddy*(config: var AppConfig, uuid: string): bool =
  let idx = config.buddies.mapIt(it.id.uuid).find(uuid)
  if idx >= 0:
    config.buddies.delete(idx)
    for i in 0..<config.folders.len:
      config.folders[i].buddies = config.folders[i].buddies.filterIt(it != uuid)
    saveConfig(config)
    result = true
  else:
    result = false

proc getFolder*(config: AppConfig, name: string): int =
  for i, folder in config.folders:
    if folder.name == name:
      return i
  return -1

proc newSyncFolder*(name, path: string, encrypted = true): FolderConfig =
  ## The only way folders should be created. A folder needs a stable id so a
  ## rename does not orphan its backup, and its own key: an "encrypted" folder
  ## without one would go to the buddy in plain form.
  result = newFolderConfig(name, path, encrypted)
  result.id = $genUuid()
  result.folderKey = generateKey()

proc hasUsableKey*(folder: FolderConfig): bool =
  folder.folderKey.len == KeySize

proc ensureFolderIdentities*(config: var AppConfig): seq[string] =
  ## Gives folders created without an id or key (older GUIs did this) the ones
  ## they should have had. Returns what was changed, for logging.
  for folder in config.folders.mitems:
    if folder.id.len == 0:
      folder.id = $genUuid()
      result.add("folder " & folder.name & " had no id; assigned " & folder.id)
    if not folder.hasUsableKey():
      folder.folderKey = generateKey()
      if folder.encrypted:
        result.add("folder " & folder.name & " had no encryption key; generated one. " &
          "Files already sent to a buddy from it were not encrypted")
      else:
        result.add("folder " & folder.name & " had no folder key; generated one " &
          "(unused while the folder is not encrypted)")

proc storageBaseDir*(config: AppConfig): string =
  if config.storageBasePath.len > 0:
    config.storageBasePath
  else:
    getDataDir() / "storage"

proc folderAppliesToBuddy*(folder: FolderConfig, buddyId: string): bool =
  folder.buddies.len == 0 or buddyId in folder.buddies

proc buddyStorageRoot*(config: AppConfig, buddyId: string): string =
  for buddy in config.buddies:
    if buddy.id.uuid == buddyId and buddy.storagePath.len > 0:
      return buddy.storagePath
  config.storageBaseDir() / buddyId

proc getBuddy*(config: AppConfig, uuid: string): int =
  for i, buddy in config.buddies:
    if buddy.id.uuid == uuid:
      return i
  return -1
