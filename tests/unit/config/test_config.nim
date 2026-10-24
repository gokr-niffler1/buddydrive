import std/unittest
import std/[os, sequtils, times, strutils]
import ../../../src/buddydrive/types
import ../../../src/buddydrive/config as buddyconfig
import ../../../src/buddydrive/crypto
import ../../testutils

suite "Config paths":
  test "getConfigDir uses BUDDYDRIVE_CONFIG_DIR env":
    withTestDir("configdir"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      defer: delEnv("BUDDYDRIVE_CONFIG_DIR")
      check buddyconfig.getConfigDir() == testDir

  test "getConfigDir defaults to ~/.buddydrive":
    delEnv("BUDDYDRIVE_CONFIG_DIR")
    check buddyconfig.getConfigDir().endsWith(".buddydrive")

  test "getDataDir uses BUDDYDRIVE_DATA_DIR env":
    withTestDir("datadir"):
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer: delEnv("BUDDYDRIVE_DATA_DIR")
      check buddyconfig.getDataDir() == testDir

  test "getDataDir defaults to configDir":
    delEnv("BUDDYDRIVE_DATA_DIR")
    check buddyconfig.getDataDir() == buddyconfig.getConfigDir()

  test "getConfigPath appends config.toml":
    check buddyconfig.getConfigPath().endsWith("config.toml")

  test "getStatePath appends state.db":
    check buddyconfig.getStatePath().endsWith("state.db")

  test "getIndexPath appends index.db":
    check buddyconfig.getIndexPath().endsWith("index.db")

suite "Config save and load":
  test "initConfig creates config file":
    withTestDir("initconfig"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      let cfg = buddyconfig.initConfig("test-buddy", "12345678-1234-1234-1234-123456789012")
      check fileExists(testDir / "config.toml")
      check cfg.buddy.name == "test-buddy"
      check cfg.buddy.uuid == "12345678-1234-1234-1234-123456789012"

  test "loadConfig reads back saved config":
    withTestDir("loadconfig"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("aaaaaaaa-1111-1111-1111-111111111111", "alice"))
      cfg.listenPort = 9999
      cfg.announceAddr = "/ip4/1.2.3.4/tcp/9999"
      cfg.apiBaseUrl = "https://relay.example.com"
      cfg.relayRegion = "eu"
      cfg.storageBasePath = testDir / "storage"
      buddyconfig.saveConfig(cfg)
      let loaded = buddyconfig.loadConfig()
      check loaded.buddy.uuid == "aaaaaaaa-1111-1111-1111-111111111111"
      check loaded.buddy.name == "alice"
      check loaded.listenPort == 9999
      check loaded.announceAddr == "/ip4/1.2.3.4/tcp/9999"
      check loaded.apiBaseUrl == "https://relay.example.com"
      check loaded.relayRegion == "eu"
      check loaded.storageBasePath == testDir / "storage"

  test "loadConfig missing file raises IOError":
    putEnv("BUDDYDRIVE_CONFIG_DIR", "/tmp/buddydrive_nonexistent_12345")
    defer: delEnv("BUDDYDRIVE_CONFIG_DIR")
    expect IOError:
      discard buddyconfig.loadConfig()

  test "saveConfig preserves recovery config":
    withTestDir("recoveryconfig"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("bb", "bob"))
      cfg.recovery.enabled = true
      cfg.recovery.publicKeyB58 = "testPubKey123"
      cfg.recovery.masterKey = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
      buddyconfig.saveConfig(cfg)
      let loaded = buddyconfig.loadConfig()
      check loaded.recovery.enabled == true
      check loaded.recovery.publicKeyB58 == "testPubKey123"
      check loaded.recovery.masterKey == "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

suite "Folder management":
  test "addFolder adds and persists folder":
    withTestDir("addfolder"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("cc", "carol"))
      buddyconfig.saveConfig(cfg)
      cfg.addFolder(newFolderConfig("docs", "/tmp/docs"))
      check cfg.folders.len == 1
      check cfg.folders[0].name == "docs"
      let reloaded = buddyconfig.loadConfig()
      check reloaded.folders.len == 1
      check reloaded.folders[0].name == "docs"

  test "removeFolder removes folder by name":
    withTestDir("removefolder"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("dd", "dave"))
      cfg.addFolder(newFolderConfig("photos", "/tmp/photos"))
      cfg.addFolder(newFolderConfig("docs", "/tmp/docs"))
      check cfg.folders.len == 2
      check cfg.removeFolder("photos")
      check cfg.folders.len == 1
      check cfg.folders[0].name == "docs"

  test "removeFolder returns false for missing folder":
    withTestDir("removefoldermiss"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("ee", "eve"))
      buddyconfig.saveConfig(cfg)
      check not cfg.removeFolder("nonexistent")

  test "folder with buddies persists":
    withTestDir("folderbuddies"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("ff", "frank"))
      buddyconfig.saveConfig(cfg)
      var folder = newFolderConfig("shared", "/tmp/shared")
      folder.buddies = @["uuid-buddy-1"]
      cfg.addFolder(folder)
      let reloaded = buddyconfig.loadConfig()
      check reloaded.folders[0].buddies.len == 1
      check reloaded.folders[0].buddies[0] == "uuid-buddy-1"

  test "folderKey persists via text-safe encoding":
    withTestDir("folderkeypersist"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      discard initCrypto()
      var cfg = newAppConfig(newBuddyId("fk", "folder-key"))
      buddyconfig.saveConfig(cfg)
      var folder = newFolderConfig("secret", "/tmp/secret")
      folder.folderKey = generateKey()
      cfg.addFolder(folder)
      let reloaded = buddyconfig.loadConfig()
      check reloaded.folders.len == 1
      check reloaded.folders[0].folderKey == folder.folderKey

  test "getFolder returns index":
    withTestDir("getfolder"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("gg", "grace"))
      buddyconfig.saveConfig(cfg)
      cfg.addFolder(newFolderConfig("a", "/tmp/a"))
      cfg.addFolder(newFolderConfig("b", "/tmp/b"))
      check cfg.getFolder("a") == 0
      check cfg.getFolder("b") == 1
      check cfg.getFolder("c") == -1

suite "Timestamps":
  test "added_at survives a save and load unchanged":
    withTestDir("addedat"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("hh", "heidi"))
      var buddy: BuddyInfo
      buddy.id = newBuddyId("buddy-1", "carol")
      buddy.addedAt = fromUnix(1_790_000_000)
      cfg.buddies = @[buddy]
      for _ in 0 ..< 3:
        buddyconfig.saveConfig(cfg)
        cfg = buddyconfig.loadConfig()
      check cfg.buddies[0].addedAt.toUnix() == 1_790_000_000

suite "Machine identity":
  test "machine id is created once and kept":
    withTestDir("machineid"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      let first = buddyconfig.machineId()
      check first.len > 0
      check buddyconfig.machineId() == first

  test "pending takeovers are cleared per buddy":
    withTestDir("takeover"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      check buddyconfig.pendingTakeovers().len == 0
      buddyconfig.requestTakeover(@["buddy-1", "buddy-2"])
      check buddyconfig.pendingTakeovers() == @["buddy-1", "buddy-2"]
      buddyconfig.clearTakeover("buddy-1")
      check buddyconfig.pendingTakeovers() == @["buddy-2"]
      buddyconfig.clearTakeover("buddy-2")
      check buddyconfig.pendingTakeovers().len == 0
      check not fileExists(buddyconfig.getTakeoverPath())

suite "Folder identity":
  test "newSyncFolder gives every folder an id and a key":
    let a = newSyncFolder("docs", "/tmp/docs")
    let b = newSyncFolder("docs", "/tmp/docs")
    check a.id.len > 0
    check a.hasUsableKey()
    check a.id != b.id
    check a.folderKey != b.folderKey

  test "ensureFolderIdentities repairs folders made without them":
    var cfg = newAppConfig(newBuddyId("hh", "heidi"))
    cfg.folders = @[newFolderConfig("gui-made", "/tmp/a"), newSyncFolder("fine", "/tmp/b")]
    let untouched = cfg.folders[1]
    let changes = cfg.ensureFolderIdentities()
    check changes.len == 2
    check cfg.folders[0].id.len > 0
    check cfg.folders[0].hasUsableKey()
    check cfg.folders[1] == untouched
    check cfg.ensureFolderIdentities().len == 0

  test "a repaired unencrypted folder is not said to have lost encryption":
    var cfg = newAppConfig(newBuddyId("hh", "heidi"))
    var plain = newFolderConfig("shared", "/tmp/c")
    plain.encrypted = false
    var sealed = newFolderConfig("private", "/tmp/d")
    sealed.encrypted = true
    cfg.folders = @[plain, sealed]
    let changes = cfg.ensureFolderIdentities()
    check changes.anyIt("shared had no folder key" in it and "not encrypted)" in it)
    check changes.anyIt("private had no encryption key" in it and "were not encrypted" in it)

suite "Buddy management":
  test "addBuddy adds and persists buddy":
    withTestDir("addbuddy"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("hh", "heidi"))
      buddyconfig.saveConfig(cfg)
      var buddy: BuddyInfo
      buddy.id = newBuddyId("ii-uuid", "ivan")
      buddy.pairingCode = "swift-eagle"
      buddy.syncWindow = "22:00-06:00"
      buddy.syncInterval = "2h"
      buddy.addedAt = getTime()
      cfg.addBuddy(buddy)
      check cfg.buddies.len == 1
      check cfg.buddies[0].id.uuid == "ii-uuid"
      check cfg.buddies[0].pairingCode == "swift-eagle"
      check cfg.buddies[0].syncWindow == "22:00-06:00"
      let reloaded = buddyconfig.loadConfig()
      check reloaded.buddies.len == 1
      check reloaded.buddies[0].id.name == "ivan"
      check reloaded.buddies[0].syncWindow == "22:00-06:00"
      check reloaded.buddies[0].syncInterval == "2h"

  test "an older sync_time is read as the sync window":
    withTestDir("legacysynctime"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("hh", "heidi"))
      buddyconfig.saveConfig(cfg)
      writeFile(getConfigPath(), readFile(getConfigPath()) &
        "\n[[buddies]]\nid = \"old-uuid\"\nname = \"olga\"\npairing_code = \"x\"\nsync_time = \"03:00\"\n")
      let reloaded = buddyconfig.loadConfig()
      check reloaded.buddies[0].syncWindow == "03:00"
      check reloaded.buddies[0].syncInterval == ""
      buddyconfig.saveConfig(reloaded)
      check "sync_window = \"03:00\"" in readFile(getConfigPath())

  test "buddy storage folder persists and has a default":
    withTestDir("buddystorage"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("hh", "heidi"))
      var custom: BuddyInfo
      custom.id = newBuddyId("custom-uuid", "carol")
      custom.storagePath = testDir / "carol-backups"
      var plain: BuddyInfo
      plain.id = newBuddyId("plain-uuid", "dave")
      plain.addresses = @["/ip4/192.168.1.101/tcp/41721"]
      cfg.buddies = @[custom, plain]
      buddyconfig.saveConfig(cfg)

      let reloaded = buddyconfig.loadConfig()
      check reloaded.buddies[0].storagePath == testDir / "carol-backups"
      check reloaded.buddies[1].addresses == @["/ip4/192.168.1.101/tcp/41721"]
      check reloaded.buddyStorageRoot("custom-uuid") == testDir / "carol-backups"
      check reloaded.buddyStorageRoot("plain-uuid") == testDir / "storage" / "plain-uuid"

      var based = reloaded
      based.storageBasePath = testDir / "base"
      check based.buddyStorageRoot("plain-uuid") == testDir / "base" / "plain-uuid"
      check based.buddyStorageRoot("custom-uuid") == testDir / "carol-backups"

  test "addBuddy updates existing buddy by uuid":
    withTestDir("updatebuddy"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("jj", "judy"))
      buddyconfig.saveConfig(cfg)
      var buddy1: BuddyInfo
      buddy1.id = newBuddyId("same-uuid", "name-one")
      buddy1.addedAt = getTime()
      cfg.addBuddy(buddy1)
      var buddy2: BuddyInfo
      buddy2.id = newBuddyId("same-uuid", "name-two")
      buddy2.pairingCode = "new-code"
      buddy2.addedAt = getTime()
      cfg.addBuddy(buddy2)
      check cfg.buddies.len == 1
      check cfg.buddies[0].id.name == "name-two"
      check cfg.buddies[0].pairingCode == "new-code"

  test "removeBuddy removes by uuid":
    withTestDir("removebuddy"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("kk", "karl"))
      buddyconfig.saveConfig(cfg)
      var b1: BuddyInfo
      b1.id = newBuddyId("uuid-1", "one")
      b1.addedAt = getTime()
      var b2: BuddyInfo
      b2.id = newBuddyId("uuid-2", "two")
      b2.addedAt = getTime()
      cfg.addBuddy(b1)
      cfg.addBuddy(b2)
      check cfg.removeBuddy("uuid-1")
      check cfg.buddies.len == 1
      check cfg.buddies[0].id.uuid == "uuid-2"

  test "removeBuddy also removes from folder buddies list":
    withTestDir("removebuddyfolder"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("ll", "leo"))
      buddyconfig.saveConfig(cfg)
      var buddy: BuddyInfo
      buddy.id = newBuddyId("uuid-x", "x-buddy")
      buddy.addedAt = getTime()
      cfg.addBuddy(buddy)
      var folder = newFolderConfig("f", "/tmp/f")
      folder.buddies = @["uuid-x", "uuid-y"]
      cfg.addFolder(folder)
      check cfg.folders[0].buddies.len == 2
      check cfg.removeBuddy("uuid-x")
      check cfg.folders[0].buddies.len == 1
      check "uuid-x" notin cfg.folders[0].buddies

  test "removeBuddy returns false for missing uuid":
    withTestDir("removebuddymiss"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("mm", "max"))
      buddyconfig.saveConfig(cfg)
      check not cfg.removeBuddy("nonexistent")

  test "getBuddy returns index":
    var cfg = newAppConfig(newBuddyId("nn", "nora"))
    var b1: BuddyInfo
    b1.id = newBuddyId("uuid-a", "a")
    var b2: BuddyInfo
    b2.id = newBuddyId("uuid-b", "b")
    cfg.buddies = @[b1, b2]
    check cfg.getBuddy("uuid-a") == 0
    check cfg.getBuddy("uuid-b") == 1
    check cfg.getBuddy("uuid-c") == -1

suite "configExists":
  test "configExists returns false when no config":
    putEnv("BUDDYDRIVE_CONFIG_DIR", "/tmp/buddydrive_nonexistent_99999")
    defer: delEnv("BUDDYDRIVE_CONFIG_DIR")
    check not buddyconfig.configExists()

  test "configExists returns true after initConfig":
    withTestDir("configexists"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      discard buddyconfig.initConfig("test", "uuid-1")
      check buddyconfig.configExists()

suite "TOML escaping":
  test "saveConfig handles special characters in name":
    withTestDir("specialchars"):
      putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
      putEnv("BUDDYDRIVE_DATA_DIR", testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      var cfg = newAppConfig(newBuddyId("uuid-esc", "name with \"quotes\""))
      buddyconfig.saveConfig(cfg)
      let loaded = buddyconfig.loadConfig()
      check loaded.buddy.name == "name with \"quotes\""
