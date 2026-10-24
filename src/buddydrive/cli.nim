import std/os
import std/strutils
import std/parseopt
import std/random
import std/times
import std/sequtils
import std/options
import uuids
import chronos
import libp2p/multiaddress
import types
import config
import crypto
import daemon
import control
import recovery
import sync/policy
import sync/config_sync
when defined(posix):
  import std/posix

export crypto.generatePairingCode

proc generateBuddyName*(): string
proc generateUuid*(): string

type
  CommandKind* = enum
    cmdNone
    cmdInit
    cmdConfig
    cmdAddFolder
    cmdRemoveFolder
    cmdListFolders
    cmdAddBuddy
    cmdRemoveBuddy
    cmdListBuddies
    cmdConnect
    cmdStart
    cmdStop
    cmdStatus
    cmdLogs
    cmdSetupRecovery
    cmdRecover
    cmdSyncConfig
    cmdExportRecovery
    cmdHelp
  
  CommandLine* = object
    command*: CommandKind
    folderPath*: string
    folderName*: string
    folderEncrypted*: bool
    folderAppendOnly*: bool
    buddyId*: string
    configAction*: string
    configKey*: string
    configTarget*: string
    configValue*: string
    pairingCode*: string
    peerAddr*: string
    generateCode*: bool
    daemon*: bool
    controlPort*: int
    showHelp*: bool

proc printHelp*() =
  echo """
BuddyDrive - P2P Encrypted Folder Sync

Usage: buddydrive <command> [options]

Commands:
  init                      Initialize BuddyDrive (generate identity)
    --with-recovery         Set up recovery during init
  config                    Show current configuration
  config set <key> ...      Update configuration values
  add-folder <path>         Add a folder to sync
    --name <name>           Folder name (required)
    --no-encrypt            Don't encrypt files
    --append-only           Only sync new files, never updates or deletions
    --buddy <id>            Add buddy to folder
  remove-folder <name>      Remove a folder
  list-folders              List configured folders
  add-buddy                 Pair with a buddy
    --id <buddy-id>         Buddy ID to pair with
    --generate-code         Generate a pairing code, save it for this
                            buddy and print the command to send them
    --code <code>           Pairing code your buddy generated
  remove-buddy <id>         Remove a buddy
  list-buddies              List paired buddies
  connect <address>         Connect to a buddy manually
                            Address format: /ip4/127.0.0.1/tcp/PORT
  start                     Start sync daemon
    --daemon                Run in background
  stop                      Stop sync daemon
  status                    Show sync status
  logs                      Show recent logs
  setup-recovery            Set up recovery with BIP39 mnemonic
  recover                   Restore from BIP39 mnemonic
  sync-config               Manually sync config to relay/buddies
  export-recovery           Show recovery phrase again
  help                      Show this help
"""

proc parseCli*(): CommandLine =
  var p = initOptParser()
  result = CommandLine(
    command: cmdNone,
    folderEncrypted: true,
    folderAppendOnly: false,
    configAction: "",
    configKey: "",
    configTarget: "",
    configValue: "",
    generateCode: false,
    daemon: false,
    controlPort: DefaultControlPort,
    showHelp: false
  )
  
  var args: seq[string] = @[]
  var pendingValue: string = ""
  
  for kind, key, val in p.getopt():
    if pendingValue.len > 0:
      case pendingValue
      of "name":
        result.folderName = key
      of "buddy", "id":
        result.buddyId = key
      of "code":
        result.pairingCode = key
      of "port":
        try:
          result.controlPort = parseInt(key)
        except ValueError:
          result.showHelp = true
      pendingValue = ""
      continue
    
    case kind
    of cmdArgument:
      args.add(key)
    of cmdLongOption, cmdShortOption:
      case key.toLower()
      of "name":
        if val.len > 0:
          result.folderName = val
        else:
          pendingValue = "name"
      of "no-encrypt":
        result.folderEncrypted = false
      of "append-only":
        result.folderAppendOnly = true
      of "buddy":
        if val.len > 0:
          result.buddyId = val
        else:
          pendingValue = "buddy"
      of "id":
        if val.len > 0:
          result.buddyId = val
        else:
          pendingValue = "id"
      of "code":
        if val.len > 0:
          result.pairingCode = val
        else:
          pendingValue = "code"
      of "generate-code":
        result.generateCode = true
      of "port", "p":
        if val.len > 0:
          try:
            result.controlPort = parseInt(val)
          except ValueError:
            result.showHelp = true
        else:
          pendingValue = "port"
      of "daemon", "d":
        result.daemon = true
      of "help", "h":
        result.showHelp = true
      else:
        echo "Unknown option: ", key
        result.showHelp = true
    of cmdEnd:
      discard
  
  if result.showHelp or args.len == 0:
    result.command = cmdHelp
    return
  
  let cmd = args[0].toLower()
  result.command = case cmd
    of "init": cmdInit
    of "config": cmdConfig
    of "add-folder": cmdAddFolder
    of "remove-folder": cmdRemoveFolder
    of "list-folders": cmdListFolders
    of "add-buddy": cmdAddBuddy
    of "remove-buddy": cmdRemoveBuddy
    of "list-buddies": cmdListBuddies
    of "connect": cmdConnect
    of "start": cmdStart
    of "stop": cmdStop
    of "status": cmdStatus
    of "logs": cmdLogs
    of "setup-recovery": cmdSetupRecovery
    of "recover": cmdRecover
    of "sync-config": cmdSyncConfig
    of "export-recovery": cmdExportRecovery
    of "help": cmdHelp
    else: cmdHelp
  
  if args.len > 1:
    case result.command
    of cmdConfig:
      result.configAction = args[1].toLowerAscii()
      if result.configAction == "set":
        if args.len >= 4:
          result.configKey = args[2].toLowerAscii()
          case result.configKey
          of "api-base-url", "api_base_url", "relay-region", "relay_region", "storage-base-path", "storage_base_path", "bandwidth-limit", "bandwidth_limit":
            result.configValue = args[3]
          of "buddy-pairing-code", "buddy_pairing_code", "buddy-name", "buddy_name", "buddy-sync-time", "buddy_sync_time", "sync-time", "sync_time", "buddy-storage-path", "buddy_storage_path", "buddy-addresses", "buddy_addresses", "folder-append-only", "folder_append_only":
            if args.len >= 5:
              result.configTarget = args[3]
              result.configValue = args[4]
            else:
              result.showHelp = true
          else:
            result.showHelp = true
        else:
          result.showHelp = true
    of cmdAddFolder:
      result.folderPath = args[1]
    of cmdRemoveFolder:
      result.folderName = args[1]
    of cmdRemoveBuddy:
      result.buddyId = args[1]
    of cmdConnect:
      result.peerAddr = args[1]
    else:
      discard

  if result.showHelp:
    result.command = cmdHelp

proc handleInit*() =
  var configExists = config.configExists()
  if configExists:
    echo "Config already exists at: ", config.getConfigPath()
    echo "Use 'buddydrive config' to view, or delete to reinitialize."
    return
  
  echo "Initializing BuddyDrive..."
  
  let name = generateBuddyName()
  let uuid = generateUuid()
  
  discard initConfig(name, uuid)
  
  echo ""
  echo "Generated buddy name: ", name
  echo "Buddy ID: ", uuid
  echo ""
  echo "Config created at: ", config.getConfigPath()
  echo ""
  echo "Network defaults:"
  echo "  Listen port: 41721"
  echo "  Announce addr: (set [network].announce_addr after forwarding this port on your router)"
  echo "  Relay base URL: (set with 'buddydrive config set api-base-url <url>')"
  echo "  Relay region: (set with 'buddydrive config set relay-region <region>')"
  echo "  Buddy sync time: always (set per buddy with 'buddydrive config set buddy-sync-time <buddy-id> HH:MM')"
  echo ""
  echo "Next steps:"
  echo "  1. Add a folder: buddydrive add-folder <path> --name <name>"
  echo "  2. Pair with a buddy: buddydrive add-buddy --generate-code --id <buddy-id>"
  echo "  3. Start syncing: buddydrive start"

proc handleConfig*(cmd: CommandLine) =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return

  if cmd.configAction == "set":
    var cfg = loadConfig()

    case cmd.configKey
    of "api-base-url", "api_base_url":
      cfg.apiBaseUrl = cmd.configValue
      saveConfig(cfg)
      echo "Relay base URL set to: ", cfg.apiBaseUrl
      return
    of "relay-region", "relay_region":
      cfg.relayRegion = cmd.configValue.toLowerAscii()
      saveConfig(cfg)
      echo "Relay region set to: ", cfg.relayRegion
      return
    of "storage-base-path", "storage_base_path":
      cfg.storageBasePath = cmd.configValue
      saveConfig(cfg)
      echo "Incoming storage base set to: ", cfg.storageBasePath
      return
    of "bandwidth-limit", "bandwidth_limit":
      let kbps = parseInt(cmd.configValue)
      if kbps < 0:
        echo "Invalid bandwidth limit. Use a non-negative number."
        return
      cfg.bandwidthLimitKBps = kbps
      saveConfig(cfg)
      if kbps == 0:
        echo "Bandwidth limit disabled (unlimited)"
      else:
        let mbps = (kbps * 8) div 1000
        echo "Bandwidth limit set to: ", kbps, " KB/s (", mbps, " Mbps)"
      return
    of "buddy-sync-time", "buddy_sync_time", "sync-time", "sync_time":
      let idx = cfg.getBuddy(cmd.configTarget)
      if idx < 0:
        echo "Buddy not found: ", cmd.configTarget.shortId()
        return
      if cmd.configValue.toLowerAscii() == "off":
        cfg.buddies[idx].syncTime = ""
      else:
        if parseClockMinutes(cmd.configValue) < 0:
          echo "Invalid sync time. Use HH:MM or 'off'."
          return
        cfg.buddies[idx].syncTime = cmd.configValue
      saveConfig(cfg)
      echo "Sync time for buddy ", cfg.buddies[idx].id.uuid.shortId(), " set to: ", syncTimeDescription(cfg.buddies[idx].syncTime)
      return
    of "buddy-pairing-code", "buddy_pairing_code", "pairing-code", "pairing_code":
      let idx = cfg.getBuddy(cmd.configTarget)
      if idx < 0:
        echo "Buddy not found: ", cmd.configTarget.shortId()
        return
      cfg.buddies[idx].pairingCode = cmd.configValue
      saveConfig(cfg)
      echo "Pairing code set for buddy: ", cfg.buddies[idx].id.uuid.shortId()
      return
    of "buddy-storage-path", "buddy_storage_path":
      let idx = cfg.getBuddy(cmd.configTarget)
      if idx < 0:
        echo "Buddy not found: ", cmd.configTarget.shortId()
        return
      cfg.buddies[idx].storagePath =
        if cmd.configValue.toLowerAscii() == "default": "" else: absolutePath(cmd.configValue)
      saveConfig(cfg)
      echo "Storage folder for buddy ", cfg.buddies[idx].id.uuid.shortId(), ": ", cfg.buddyStorageRoot(cfg.buddies[idx].id.uuid)
      return
    of "buddy-addresses", "buddy_addresses":
      let idx = cfg.getBuddy(cmd.configTarget)
      if idx < 0:
        echo "Buddy not found: ", cmd.configTarget.shortId()
        return
      var addresses: seq[string] = @[]
      if cmd.configValue.toLowerAscii() != "none":
        for value in cmd.configValue.split(','):
          let address = value.strip()
          if MultiAddress.init(address).isErr:
            echo "Invalid address: ", address, " (use /ip4/<ip>/tcp/<port>)"
            return
          addresses.add(address)
      cfg.buddies[idx].addresses = addresses
      saveConfig(cfg)
      if addresses.len == 0:
        echo "Known addresses cleared for buddy ", cfg.buddies[idx].id.uuid.shortId()
      else:
        echo "Known addresses for buddy ", cfg.buddies[idx].id.uuid.shortId(), ": ", addresses.join(", ")
      return
    of "buddy-name", "buddy_name":
      let idx = cfg.getBuddy(cmd.configTarget)
      if idx < 0:
        echo "Buddy not found: ", cmd.configTarget.shortId()
        return
      cfg.buddies[idx].id.name = cmd.configValue
      saveConfig(cfg)
      echo "Buddy name set to: ", cfg.buddies[idx].id.name
      return
    of "folder-append-only", "folder_append_only":
      let idx = cfg.getFolder(cmd.configTarget)
      if idx < 0:
        echo "Folder not found: ", cmd.configTarget
        return
      let normalized = cmd.configValue.toLowerAscii()
      if normalized in ["on", "true", "yes", "1"]:
        cfg.folders[idx].appendOnly = true
      elif normalized in ["off", "false", "no", "0"]:
        cfg.folders[idx].appendOnly = false
      else:
        echo "Invalid append-only value. Use on/off."
        return
      saveConfig(cfg)
      echo "Append-only for folder '", cfg.folders[idx].name, "' set to: ", cfg.folders[idx].appendOnly
      return
    else:
      echo "Unknown config key: ", cmd.configKey
      echo "Supported keys: api-base-url, relay-region, storage-base-path, bandwidth-limit, buddy-pairing-code, buddy-name, buddy-sync-time, buddy-storage-path, buddy-addresses, folder-append-only"
      return

  let cfg = loadConfig()
  
  echo "Buddy: ", cfg.buddy.name
  echo "  ID: ", cfg.buddy.uuid
  echo "  Config: ", config.getConfigPath()
  echo "  Listen port: ", cfg.listenPort
  if cfg.announceAddr.len > 0:
    echo "  Announce addr: ", cfg.announceAddr
  else:
    echo "  Announce addr: (not set)"
  if cfg.apiBaseUrl.len > 0:
    echo "  Relay base URL: ", cfg.apiBaseUrl
  else:
    echo "  Relay base URL: (not set)"
  if cfg.relayRegion.len > 0:
    echo "  Relay region: ", cfg.relayRegion
  else:
    echo "  Relay region: (not set)"
  if cfg.storageBasePath.len > 0:
    echo "  Incoming storage base: ", cfg.storageBasePath
    echo "    Layout: <storage base>/<buddy id>/<folder name>/..."
  else:
    echo "  Incoming storage base: (not set)"
  if cfg.bandwidthLimitKBps > 0:
    echo "  Bandwidth limit: ", cfg.bandwidthLimitKBps, " KB/s"
  else:
    echo "  Bandwidth limit: unlimited"
  echo ""
  
  if cfg.folders.len > 0:
    echo "Folders:"
    for folder in cfg.folders:
      echo "  ", folder.name
      echo "    Path: ", folder.path
      echo "    Encrypted: ", folder.encrypted
      echo "    Append-only: ", folder.appendOnly
      if folder.buddies.len > 0:
        echo "    Buddies: ", folder.buddies.join(", ")
    echo ""
  
  if cfg.buddies.len > 0:
    echo "Buddies:"
    for buddy in cfg.buddies:
      echo "  ", buddy.id.name, " (", shortId(buddy.id.uuid), ")"
      echo "    ID: ", buddy.id.uuid
      if buddy.pairingCode.len > 0:
        echo "    Pairing code: ", buddy.pairingCode
      echo "    Sync time: ", syncTimeDescription(buddy.syncTime)
      echo "    Added: ", buddy.addedAt.format("yyyy-MM-dd HH:mm:ss")
  else:
    echo "No buddies paired yet."
    echo "Use 'buddydrive add-buddy --generate-code --id <buddy-id>' to pair."

proc handleAddFolder*(cmd: CommandLine) =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  if cmd.folderPath.len == 0:
    echo "Error: Folder path required"
    echo "Usage: buddydrive add-folder <path> --name <name>"
    return
  
  if cmd.folderName.len == 0:
    echo "Error: Folder name required"
    echo "Usage: buddydrive add-folder <path> --name <name>"
    return
  
  let absPath = absolutePath(cmd.folderPath)
  if not dirExists(absPath):
    echo "Error: Directory does not exist: ", absPath
    return
  
  var cfg = loadConfig()
  
  if cfg.getFolder(cmd.folderName) >= 0:
    echo "Error: Folder name already exists: ", cmd.folderName
    return
  
  var folder = newSyncFolder(cmd.folderName, absPath, cmd.folderEncrypted)
  folder.appendOnly = cmd.folderAppendOnly
  
  if cmd.buddyId.len > 0:
    let buddyIdx = cfg.getBuddy(cmd.buddyId)
    if buddyIdx < 0:
      echo "Warning: Buddy not found: ", cmd.buddyId
    else:
      folder.buddies.add(cmd.buddyId)
  
  cfg.addFolder(folder)
  
  echo "Folder added: ", cmd.folderName
  echo "  Path: ", absPath
  echo "  Encrypted: ", cmd.folderEncrypted
  echo "  Append-only: ", folder.appendOnly
  if folder.buddies.len > 0:
    echo "  Buddies: ", folder.buddies.join(", ")

proc handleRemoveFolder*(cmd: CommandLine) =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  if cmd.folderName.len == 0:
    echo "Error: Folder name required"
    return
  
  var cfg = loadConfig()
  
  if cfg.removeFolder(cmd.folderName):
    echo "Folder removed: ", cmd.folderName
  else:
    echo "Folder not found: ", cmd.folderName

proc handleListFolders*() =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  let cfg = loadConfig()
  
  if cfg.folders.len == 0:
    echo "No folders configured."
    echo "Use 'buddydrive add-folder <path> --name <name>' to add one."
    return
  
  echo "Folders:"
  for folder in cfg.folders:
    echo "  ", folder.name
    echo "    Path: ", folder.path
    echo "    Encrypted: ", folder.encrypted
    echo "    Append-only: ", folder.appendOnly
    if folder.buddies.len > 0:
      echo "    Buddies: ", folder.buddies.join(", ")

proc storeBuddyCode(buddyId: string, code: string) =
  ## Adds the buddy, or updates the code of one we already have without
  ## losing its other settings.
  var cfg = loadConfig()
  var buddy: BuddyInfo
  let idx = cfg.getBuddy(buddyId)
  if idx >= 0:
    buddy = cfg.buddies[idx]
  else:
    buddy.id.uuid = buddyId
    buddy.addedAt = getTime()
  buddy.pairingCode = code
  cfg.addBuddy(buddy)

proc handleAddBuddy*(cmd: CommandLine) =
  ## Both buddies must store the same pairing code for each other: it keys the
  ## discovery record and the relay rendezvous. One side generates it, the
  ## other enters it.
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return

  let cfg = loadConfig()

  if cmd.generateCode:
    if cmd.buddyId.len == 0:
      echo "Error: Buddy ID required, so the code can be saved for that buddy"
      echo "Usage: buddydrive add-buddy --generate-code --id <buddy-id>"
      echo ""
      echo "Your Buddy ID, to give to your buddy: ", cfg.buddy.uuid
      return
    let code = generatePairingCode()
    storeBuddyCode(cmd.buddyId, code)
    echo "Buddy added: ", cmd.buddyId.shortId(), " with pairing code ", code
    echo ""
    echo "Send your buddy this command:"
    echo "  buddydrive add-buddy --id ", cfg.buddy.uuid, " --code ", code
    echo ""
    echo "The code is a secret: anyone who has it can find your buddy's address."
    return

  if cmd.buddyId.len == 0 or cmd.pairingCode.len == 0:
    echo "Error: Buddy ID and pairing code required"
    echo "Usage: buddydrive add-buddy --id <buddy-id> --code <code>"
    echo "   or: buddydrive add-buddy --generate-code --id <buddy-id>"
    return

  storeBuddyCode(cmd.buddyId, cmd.pairingCode)
  echo "Buddy added: ", cmd.buddyId.shortId(), " with pairing code ", cmd.pairingCode
  echo "Start the daemon with 'buddydrive start' to connect."

proc handleRemoveBuddy*(cmd: CommandLine) =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  if cmd.buddyId.len == 0:
    echo "Error: Buddy ID required"
    return
  
  var cfg = loadConfig()
  
  if cfg.removeBuddy(cmd.buddyId):
    echo "Buddy removed: ", cmd.buddyId.shortId()
  else:
    echo "Buddy not found: ", cmd.buddyId.shortId()

proc handleListBuddies*() =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  let cfg = loadConfig()
  
  if cfg.buddies.len == 0:
    echo "No buddies paired yet."
    echo "Use 'buddydrive add-buddy --generate-code --id <buddy-id>' to pair."
    return
  
  echo "Buddies:"
  for buddy in cfg.buddies:
    echo "  ", buddy.id.name, " (", buddy.id.uuid.shortId(), ")"
    echo "    ID: ", buddy.id.uuid
    if buddy.pairingCode.len > 0:
      echo "    Pairing code: ", buddy.pairingCode
    echo "    Storage: ", cfg.buddyStorageRoot(buddy.id.uuid)
    if buddy.addresses.len > 0:
      echo "    Known addresses: ", buddy.addresses.join(", ")
    echo "    Added: ", buddy.addedAt.format("yyyy-MM-dd HH:mm:ss")

proc handleConnect*(cmd: CommandLine) =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  if cmd.peerAddr.len == 0:
    echo "Error: Peer address required"
    echo "Usage: buddydrive connect <peer-id> <address>"
    echo "Example: buddydrive connect 16Uiu2HAk... /ip4/127.0.0.1/tcp/12345"
    return
  
  echo "Note: Direct connection not yet implemented."
  echo "Use 'buddydrive start' to connect via relay discovery."

var shutdownSignalled: bool

when defined(posix):
  proc onShutdownSignal(sig: cint) {.noconv.} =
    ## Only sets a flag: the run loop does the actual shutdown, which cannot
    ## happen inside a signal handler. A second signal exits at once, in case
    ## the clean shutdown hangs.
    if shutdownSignalled:
      exitnow(128 + sig)
    shutdownSignalled = true

  proc installShutdownHandlers() =
    discard signal(SIGINT, onShutdownSignal)
    discard signal(SIGTERM, onShutdownSignal)
else:
  proc installShutdownHandlers() =
    setControlCHook(proc() {.noconv.} = shutdownSignalled = true)

proc handleStart*(cmd: CommandLine) =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  let cfg = loadConfig()
  let daemon = newDaemon(cfg)
  
  echo "Starting BuddyDrive daemon..."
  echo ""
  
  if cmd.daemon:
    echo "Background mode (daemonizing)..."
    echo ""
    echo "Note: Background daemon mode not fully implemented."
    echo "Running in foreground instead..."
    echo ""
  
  proc runDaemon() {.async.} =
    try:
      await daemon.start(cmd.controlPort)
      echo ""
      echo "BuddyDrive is running!"
      echo "Peer ID: ", daemon.node.peerIdStr()
      echo "Control API: http://127.0.0.1:", cmd.controlPort
      echo ""
      echo "Listening addresses:"
      for address in daemon.node.getAddrs():
        let addrStr = multiaddress.toString(address)
        if addrStr.isOk:
          echo "  ", addrStr.get()
        else:
          echo "  (invalid address)"
      echo ""
      echo "Advertised addresses:"
      for address in daemon.node.getAdvertisedAddrs():
        let addrStr = multiaddress.toString(address)
        if addrStr.isOk:
          echo "  ", addrStr.get()
        else:
          echo "  (invalid address)"
      echo ""
      echo "Folders:"
      for folder in cfg.folders:
        echo "  ", folder.name, " -> ", folder.path
      echo ""
      echo "Press Ctrl+C to stop..."

      while daemon.isRunning() and not shutdownSignalled:
        await sleepAsync(chronos.seconds(1))
      if shutdownSignalled:
        echo "Shutdown requested, stopping cleanly..."
    except Exception as e:
      echo "Error: ", e.msg
    finally:
      await daemon.stop()
  
  installShutdownHandlers()
  waitFor runDaemon()

proc handleStop*() =
  ## Asks a running daemon to shut down cleanly; it checks for the request
  ## every couple of seconds.
  requestDaemonStop()
  echo "Stop requested. The daemon unpublishes itself and exits within a few seconds."

proc handleStatus*() =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  let cfg = loadConfig()
  
  echo "Buddy: ", cfg.buddy.name, " (", cfg.buddy.uuid.shortId(), ")"
  echo "Peer ID: ", "(run 'buddydrive start' to connect)"
  if cfg.storageBasePath.len > 0:
    echo "Incoming storage base: ", cfg.storageBasePath
    echo "  Layout: <storage base>/<buddy id>/<folder name>/..."
  echo ""
  
  if cfg.folders.len > 0:
    echo "Folders:"
    for folder in cfg.folders:
      echo "  ", folder.name
      echo "    Path: ", folder.path
      echo "    Encrypted: ", folder.encrypted
      echo "    Append-only: ", folder.appendOnly
      if folder.buddies.len > 0:
        echo "    Buddies: ", folder.buddies.mapIt(shortId(it)).join(", ")
  else:
    echo "No folders configured."
    echo "Use 'buddydrive add-folder <path> --name <name>' to add one."
  
  echo ""
  if cfg.buddies.len > 0:
    echo "Buddies:"
    for buddy in cfg.buddies:
      echo "  ", buddy.id.name, " (", buddy.id.uuid.shortId(), ")"
      echo "    Sync time: ", syncTimeDescription(buddy.syncTime)
      echo "    Status: Offline"
      if buddy.pairingCode.len > 0:
        echo "    Pairing code: ", buddy.pairingCode
      echo "    Added: ", buddy.addedAt.format("yyyy-MM-dd HH:mm:ss")
  else:
    echo "No buddies paired."
    echo "Use 'buddydrive add-buddy --generate-code --id <buddy-id>' to pair."

proc handleLogs*() =
  let logPath = config.getLogPath()
  if not fileExists(logPath):
    echo "No log file found."
    return
  
  echo "Recent logs from: ", logPath
  echo "---"
  echo readFile(logPath)

proc handleSetupRecovery*() =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  echo "Setting up recovery..."
  echo ""
  
  let (mnemonic, recovery) = setupRecovery()
  let words = mnemonic.split(" ")
  
  echo "Your recovery phrase:"
  echo ""
  echo "┌─────────────────────────────────────────────────────┐"
  for i in 0 ..< words.len:
    let lineStart = if i mod 4 == 0: "│" else: ""
    let lineEnd = if i mod 4 == 3: "│\n" else: ""
    if i mod 4 == 0:
      stdout.write("│ ")
    stdout.write($(i + 1) & ". " & words[i] & "  ")
    if i mod 4 == 3:
      echo ""
  echo "└─────────────────────────────────────────────────────┘"
  echo ""
  echo "⚠ Write down these 12 words and keep them safe."
  echo "  Anyone with this phrase can access your synced files."
  echo ""
  
  echo "Type your recovery phrase to confirm you wrote it down:"
  echo "(Enter 3 words: word 3, word 7, word 11)"
  stdout.write("Word 3: ")
  let word3 = stdin.readLine().strip().toLowerAscii()
  stdout.write("Word 7: ")
  let word7 = stdin.readLine().strip().toLowerAscii()
  stdout.write("Word 11: ")
  let word11 = stdin.readLine().strip().toLowerAscii()
  
  if word3 != words[2].toLowerAscii() or word7 != words[6].toLowerAscii() or word11 != words[10].toLowerAscii():
    echo ""
    echo "Words don't match. Please try again with 'buddydrive setup-recovery'"
    return
  
  var cfg = loadConfig()
  cfg.recovery = recovery
  saveConfig(cfg)
  
  echo ""
  echo "Recovery set up successfully!"
  echo "Public key: ", recovery.publicKeyB58
  
  echo "Syncing config to relay..."

  let relayUrl = if cfg.apiBaseUrl.len > 0: cfg.apiBaseUrl else: DefaultKvApiUrl
  let synced = waitFor syncConfigToRelay(cfg, relayUrl)
  if synced:
    echo "Config synced to relay."
  else:
    echo "Failed to sync config to relay."

proc handleRecover*() =
  echo "Recovery Mode"
  echo "============="
  echo ""
  echo "Enter your 12-word recovery phrase:"
  stdout.write("> ")
  let mnemonic = stdin.readLine().strip()
  
  if not validateMnemonic(mnemonic):
    echo "Invalid recovery phrase. Must be 12 words separated by spaces."
    return
  
  echo ""
  echo "Attempting to recover from relay..."

  var relayUrl = DefaultKvApiUrl
  var relayRegion = "eu"
  if config.configExists():
    let cfg = loadConfig()
    if cfg.apiBaseUrl.len > 0:
      relayUrl = cfg.apiBaseUrl
    if cfg.relayRegion.len > 0:
      relayRegion = cfg.relayRegion

  let configOpt = waitFor attemptRecovery(mnemonic, relayUrl, relayRegion)
  
  if configOpt.isSome:
    let cfg = configOpt.get()
    saveConfig(cfg)
    echo ""
    echo "Recovery successful!"
    echo ""
    echo "Identity: ", cfg.buddy.name
    echo "Buddies: ", cfg.buddies.len
    echo "Folders: ", cfg.folders.len
    echo ""
    echo "Run 'buddydrive start' to sync your folders."
  else:
    echo ""
    echo "Could not recover from relay (see the reason above)."
    echo ""
    echo "To recover from a buddy, provide their info:"
    stdout.write("Buddy ID: ")
    let buddyId = stdin.readLine().strip()
    stdout.write("Pairing code: ")
    let pairingCode = stdin.readLine().strip()
    
    if buddyId.len > 0 and pairingCode.len > 0:
      echo ""
      echo "Buddy-based recovery is not implemented yet."
      discard waitFor attemptRecoveryFromBuddy(mnemonic, buddyId, pairingCode, relayUrl, relayRegion)
    else:
      echo ""
      echo "Recovery cancelled."

proc handleSyncConfig*() =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  let cfg = loadConfig()
  
  if not cfg.recovery.enabled:
    echo "Recovery not enabled. Run 'buddydrive setup-recovery' first."
    return
  
  let kvUrl = if cfg.apiBaseUrl.len > 0: cfg.apiBaseUrl else: DefaultKvApiUrl
  echo "Syncing config to relay: ", kvUrl
  
  let success = waitFor syncConfigToRelay(cfg, kvUrl)
  
  if success:
    echo "Config synced successfully!"
  else:
    echo "Failed to sync config to relay."
  
  if cfg.buddies.len > 0:
    echo "Buddy config sync is not implemented yet."

proc handleExportRecovery*() =
  if not config.configExists():
    echo "No config found. Run 'buddydrive init' first."
    return
  
  let cfg = loadConfig()
  
  if not cfg.recovery.enabled:
    echo "Recovery not enabled."
    return
  
  echo "Exporting recovery info..."
  echo ""
  echo "Public key: ", cfg.recovery.publicKeyB58
  echo "Master key: ", cfg.recovery.masterKey
  echo ""
  echo "Note: To see your full recovery phrase, you need to have written it down"
  echo "during setup. The phrase is not stored for security reasons."
  echo ""
  echo "If you've lost your recovery phrase, you can generate a new one with:"
  echo "  buddydrive setup-recovery"
  echo ""
  echo "Warning: This will create a new recovery setup. You'll need to"
  echo "re-share any recovery info with your buddies."

proc generateBuddyName*(): string =
  let adjPath = currentSourcePath().parentDir().parentDir().parentDir() / "wordlists" / "adjectives.txt"
  let nounPath = currentSourcePath().parentDir().parentDir().parentDir() / "wordlists" / "nouns.txt"
  
  var adjectives: seq[string] = @[]
  var nouns: seq[string] = @[]
  
  if fileExists(adjPath):
    for line in lines(adjPath):
      if line.len > 0:
        adjectives.add(line.strip())
  
  if fileExists(nounPath):
    for line in lines(nounPath):
      if line.len > 0:
        nouns.add(line.strip())
  
  if adjectives.len == 0:
    adjectives = @["purple", "happy", "clever", "brave", "swift"]
  
  if nouns.len == 0:
    nouns = @["banana", "wrench", "dolphin", "falcon", "tiger"]
  
  randomize()
  let adj = adjectives[rand(adjectives.len - 1)]
  let noun = nouns[rand(nouns.len - 1)]
  
  result = adj & "-" & noun

proc generateUuid*(): string =
  let uuid = genUuid()
  result = $uuid

