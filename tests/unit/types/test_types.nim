import std/unittest
import ../../../src/buddydrive/types

suite "BuddyId":
  test "newBuddyId creates BuddyId with uuid and name":
    let id = newBuddyId("12345678-1234-1234-1234-123456789012", "alice")
    check id.uuid == "12345678-1234-1234-1234-123456789012"
    check id.name == "alice"

  test "newBuddyId defaults name to empty":
    let id = newBuddyId("12345678-1234-1234-1234-123456789012")
    check id.name == ""

  test "BuddyId $ with name shows name and short uuid":
    let id = newBuddyId("12345678-1234-1234-1234-123456789012", "bob")
    check $id == "bob (12345678...)"

  test "BuddyId $ without name shows short uuid only":
    let id = newBuddyId("12345678-1234-1234-1234-123456789012")
    check $id == "12345678..."

  test "shortId truncates long ids":
    check shortId("12345678-1234-1234-1234-123456789012") == "12345678..."

  test "shortId returns short ids unchanged":
    check shortId("abc") == "abc"

  test "shortId handles 8-char boundary":
    check shortId("12345678") == "12345678"

suite "FolderConfig":
  test "newFolderConfig creates folder with defaults":
    let f = newFolderConfig("docs", "/tmp/docs")
    check f.name == "docs"
    check f.path == "/tmp/docs"
    check f.encrypted == true
    check f.appendOnly == false
    check f.buddies.len == 0

  test "newFolderConfig with encrypted=false":
    let f = newFolderConfig("photos", "/tmp/photos", encrypted = false)
    check f.encrypted == false

suite "AppConfig":
  test "newAppConfig sets defaults":
    let cfg = newAppConfig(newBuddyId("uuid", "test"))
    check cfg.buddy.uuid == "uuid"
    check cfg.buddy.name == "test"
    check cfg.recovery.enabled == false
    check cfg.recovery.publicKeyB58 == ""
    check cfg.recovery.masterKey == ""
    check cfg.listenPort == DefaultP2PPort
    check cfg.announceAddr == ""
    check cfg.apiBaseUrl == "https://api.buddydrive.org"
    check cfg.relayRegion == "eu"
    check cfg.storageBasePath == ""
    check cfg.bandwidthLimitKBps == 0
    check cfg.folders.len == 0
    check cfg.buddies.len == 0

suite "ConnectionState":
  test "ConnectionState prints the names the GUIs expect":
    check $csDisconnected == "disconnected"
    check $csConnecting == "connecting"
    check $csConnected == "connected"
    check $csSyncing == "syncing"
    check $csError == "error"

suite "FileChangeKind":
  test "FileChangeKind enum values":
    check $fcAdded == "fcAdded"
    check $fcModified == "fcModified"
    check $fcDeleted == "fcDeleted"
