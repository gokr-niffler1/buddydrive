import std/[json, os, strutils, times, unittest]
import db_connector/db_sqlite
import ../../../src/buddydrive/config as buddyconfig
import ../../../src/buddydrive/control
import ../../../src/buddydrive/types
import ../../testutils

proc responseJson(response: string): JsonNode =
  let parts = response.split("\r\n\r\n", 1)
  check parts.len == 2
  parseJson(parts[1])

proc responseStatus(response: string): int =
  let firstLine = response.splitLines()[0]
  firstLine.split(" ")[1].parseInt()

proc initTestConfig(testDir: string, name = "tester", uuid = "12345678-1234-1234-1234-123456789012") =
  putEnv("BUDDYDRIVE_CONFIG_DIR", testDir)
  putEnv("BUDDYDRIVE_DATA_DIR", testDir)
  discard buddyconfig.initConfig(name, uuid)

suite "parseRequest":
  test "parses GET request":
    let req = parseRequest("GET /status HTTP/1.1\r\nHost: localhost\r\n\r\n")
    check req.httpMethod == "GET"
    check req.path == "/status"
    check req.body == ""

  test "parses POST request with body":
    let body = """{"name":"photos"}"""
    let raw = "POST /folders HTTP/1.1\r\nHost: localhost\r\n\r\n" & body
    let req = parseRequest(raw)
    check req.httpMethod == "POST"
    check req.path == "/folders"
    check req.body == body

  test "parses DELETE request":
    let req = parseRequest("DELETE /folders/photos HTTP/1.1\r\nHost: localhost\r\n\r\n")
    check req.httpMethod == "DELETE"
    check req.path == "/folders/photos"

  test "handles empty request gracefully":
    let req = parseRequest("")
    check req.httpMethod == ""
    check req.path == ""

  test "parses path with query string":
    let req = parseRequest("GET /status?detail=1 HTTP/1.1\r\n\r\n")
    check req.path == "/status?detail=1"

suite "handleRequest routing":
  test "unknown GET path returns 404":
    let resp = handleRequest("GET /nonexistent HTTP/1.1\r\n\r\n")
    check "404" in resp

  test "unsupported method returns 400":
    let resp = handleRequest("PATCH /status HTTP/1.1\r\n\r\n")
    check "400" in resp

  test "response starts with HTTP/1.1":
    let resp = handleRequest("GET /status HTTP/1.1\r\n\r\n")
    check resp.startsWith("HTTP/1.1")

  test "response contains JSON content type":
    let resp = handleRequest("GET /status HTTP/1.1\r\n\r\n")
    check "Content-Type: application/json" in resp

suite "web GUI addresses":
  test "one LAN URL per address, behind the secret":
    check webGuiUrls(17521, "b2050a4c-06c5-4377-b7e8-fb00ef871d0e", @["192.168.1.101"]) == @[
      "http://127.0.0.1:17521/", "http://192.168.1.101:17521/w/b2050a4c/"]

  test "a placeholder when no LAN address is known":
    check webGuiUrls(17521, "b2050a4c-06c5-4377-b7e8-fb00ef871d0e", @[])[1] == "http://<your-ip>:17521/w/b2050a4c/"

suite "control API handlers":
  test "POST /buddies/pair stores pairing code":
    withTestDir("controlpair"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)

      let response = handleRequest(
        "POST /buddies/pair HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" &
        "{\"buddyId\":\"buddy-1\",\"buddyName\":\"Alice\",\"code\":\"swift-eagle\"}"
      )

      check responseStatus(response) == 200
      let body = responseJson(response)
      check body["ok"].getBool()

      let cfg = buddyconfig.loadConfig()
      check cfg.buddies.len == 1
      check cfg.buddies[0].id.uuid == "buddy-1"
      check cfg.buddies[0].id.name == "Alice"
      check cfg.buddies[0].pairingCode == "swift-eagle"

  test "POST /buddies/pair rejects missing code":
    withTestDir("controlpairbad"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)

      let response = handleRequest(
        "POST /buddies/pair HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" &
        "{\"buddyId\":\"buddy-1\"}"
      )

      check responseStatus(response) == 400
      let body = responseJson(response)
      check body["code"].getStr() == "INVALID_REQUEST"

  test "POST /buddies/pair requires a name for the buddy":
    withTestDir("controlpairnoname"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)

      let response = handleRequest(
        "POST /buddies/pair HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" &
        "{\"buddyId\":\"buddy-1\",\"buddyName\":\"  \",\"code\":\"swift-eagle\"}"
      )

      check responseStatus(response) == 400
      check buddyconfig.loadConfig().buddies.len == 0

  test "the GUI locale is stored in config.toml and can be cleared":
    withTestDir("controllocale"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)
      let setLocale = proc (locale: string): int =
        responseStatus(handleRequest("POST /config HTTP/1.1\r\n\r\n" & $(%*{"gui": {"locale": locale}})))

      check setLocale("sv-SE") == 200
      check buddyconfig.loadConfig().guiLocale == "sv-SE"
      check "[gui]\nlocale = \"sv-SE\"" in readFile(buddyconfig.getConfigPath())
      check responseJson(handleRequest("GET /config HTTP/1.1\r\n\r\n"))["gui"]["locale"].getStr() == "sv-SE"

      check setLocale("sv SE") == 400
      check setLocale("\"; rm") == 400
      check buddyconfig.loadConfig().guiLocale == "sv-SE"

      check setLocale("") == 200
      check buddyconfig.loadConfig().guiLocale == ""
      check "[gui]" notin readFile(buddyconfig.getConfigPath())

  test "isLocaleTag":
    check isLocaleTag("")
    check isLocaleTag("sv")
    check isLocaleTag("sv-SE")
    check isLocaleTag("zh-Hant-TW")
    check not isLocaleTag("-SE")
    check not isLocaleTag("sv--SE")
    check not isLocaleTag("sv_SE")
    check not isLocaleTag("1sv")

  test "POST /buddies/update renames a buddy and sets when to sync":
    withTestDir("controlbuddyupdate"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)
      discard handleRequest(
        "POST /buddies/pair HTTP/1.1\r\n\r\n" &
        "{\"buddyId\":\"buddy-1\",\"buddyName\":\"Alice\",\"code\":\"swift-eagle\"}"
      )

      let update = proc (body: JsonNode): string =
        handleRequest("POST /buddies/update HTTP/1.1\r\n\r\n" & $body)

      check responseStatus(update(%*{"id": "buddy-1", "name": "Alice B", "sync_window": "22:00-06:00", "sync_interval": "2h"})) == 200
      var cfg = buddyconfig.loadConfig()
      check cfg.buddies[0].id.name == "Alice B"
      check cfg.buddies[0].syncWindow == "22:00-06:00"
      check cfg.buddies[0].syncInterval == "2h"
      check cfg.buddies[0].pairingCode == "swift-eagle"

      let buddies = responseJson(handleRequest("GET /buddies HTTP/1.1\r\n\r\n"))["buddies"]
      check buddies[0]["name"].getStr() == "Alice B"
      check buddies[0]["syncWindow"].getStr() == "22:00-06:00"
      check buddies[0]["syncIntervalText"].getStr() == "every 2h"

      check responseStatus(update(%*{"id": "buddy-1", "name": ""})) == 400
      check responseStatus(update(%*{"id": "buddy-1", "sync_window": "late"})) == 400
      check responseStatus(update(%*{"id": "buddy-1", "sync_interval": "2 days"})) == 400
      check responseStatus(update(%*{"id": "nobody", "name": "X"})) == 404
      check buddyconfig.loadConfig().buddies[0].syncInterval == "2h"

      check responseStatus(update(%*{"id": "buddy-1", "sync_window": "", "sync_interval": ""})) == 200
      cfg = buddyconfig.loadConfig()
      check cfg.buddies[0].syncWindow == ""
      check cfg.buddies[0].syncInterval == ""

  test "POST /recovery/setup enables recovery and returns 12 words":
    withTestDir("controlrecoverysetup"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)

      let response = handleRequest("POST /recovery/setup HTTP/1.1\r\n\r\n")
      check responseStatus(response) == 200

      let body = responseJson(response)
      check body["ok"].getBool()
      check body["words"].len == 12

      let cfg = buddyconfig.loadConfig()
      check cfg.recovery.enabled
      check cfg.recovery.publicKeyB58.len > 0
      check cfg.recovery.masterKey.len == 64

  test "POST /recovery/verify-word validates against pending setup words":
    withTestDir("controlverifyword"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)

      let setupResp = handleRequest("POST /recovery/setup HTTP/1.1\r\n\r\n")
      let setupJson = responseJson(setupResp)
      let words = setupJson["words"]
      let correctWord = words[3].getStr()

      let okResp = handleRequest(
        "POST /recovery/verify-word HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" &
        "{\"index\":3,\"word\":\"" & correctWord & "\"}"
      )
      check responseStatus(okResp) == 200
      check responseJson(okResp)["correct"].getBool()

      let badResp = handleRequest(
        "POST /recovery/verify-word HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" &
        "{\"index\":3,\"word\":\"wrongword\"}"
      )
      check responseStatus(badResp) == 200
      check not responseJson(badResp)["correct"].getBool()

  test "POST /recovery/verify-word rejects invalid index":
    withTestDir("controlverifyindex"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)
      discard handleRequest("POST /recovery/setup HTTP/1.1\r\n\r\n")

      let response = handleRequest(
        "POST /recovery/verify-word HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" &
        "{\"index\":12,\"word\":\"anything\"}"
      )

      check responseStatus(response) == 400
      check responseJson(response)["code"].getStr() == "INVALID_INDEX"

  test "POST /recovery/recover rejects mnemonic that does not match stored config":
    withTestDir("controlrecovermismatch"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)

      let setupResp = handleRequest("POST /recovery/setup HTTP/1.1\r\n\r\n")
      let setupJson = responseJson(setupResp)
      let mnemonic = setupJson["mnemonic"].getStr()

      var cfg = buddyconfig.loadConfig()
      cfg.recovery.masterKey = repeat("0", 64)
      buddyconfig.saveConfig(cfg)

      let response = handleRequest(
        "POST /recovery/recover HTTP/1.1\r\nContent-Type: application/json\r\n\r\n" &
        "{\"mnemonic\":\"" & mnemonic & "\"}"
      )

      check responseStatus(response) == 400
      check responseJson(response)["code"].getStr() == "MISMATCH"

  test "POST /recovery/sync-config rejects when recovery not enabled":
    withTestDir("controlsyncconfig"):
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      initTestConfig(testDir)

      let response = handleRequest("POST /recovery/sync-config HTTP/1.1\r\n\r\n")
      check responseStatus(response) == 400
      check responseJson(response)["code"].getStr() == "NOT_SETUP"

suite "Folder endpoints":
  proc post(path: string, body: JsonNode): string =
    handleRequest("POST " & path & " HTTP/1.1\r\nHost: localhost\r\n\r\n" & $body)

  test "adding a folder gives it an id and a key":
    withTestDir("control_add_folder"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      let response = post("/folders", %*{"name": "docs", "path": testDir, "appendOnly": true,
        "buddies": ["buddy-1"]})
      check responseStatus(response) == 200
      let folder = buddyconfig.loadConfig().folders[0]
      check folder.id.len > 0
      check folder.hasUsableKey()
      check folder.encrypted
      check folder.appendOnly
      check folder.buddies == @["buddy-1"]
      check responseStatus(post("/folders", %*{"name": "docs", "path": testDir})) == 409

  test "updating a folder changes sharing but keeps its id and key":
    withTestDir("control_update_folder"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      discard post("/folders", %*{"name": "docs", "path": testDir})
      let before = buddyconfig.loadConfig().folders[0]
      let response = post("/folders/update", %*{"id": before.id, "name": "papers",
        "path": testDir, "appendOnly": true, "buddies": ["buddy-2"]})
      check responseStatus(response) == 200
      let after = buddyconfig.loadConfig().folders[0]
      check after.name == "papers"
      check after.appendOnly
      check after.buddies == @["buddy-2"]
      check after.id == before.id
      check after.folderKey == before.folderKey
      check responseStatus(post("/folders/update", %*{"id": "missing"})) == 404

  test "POST /config keeps folder keys and buddy settings":
    withTestDir("control_config_keeps_keys"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      discard post("/folders", %*{"name": "docs", "path": testDir})
      var cfg = buddyconfig.loadConfig()
      var buddy: BuddyInfo
      buddy.id = newBuddyId("buddy-1", "carol")
      buddy.storagePath = testDir / "carol"
      buddy.addresses = @["/ip4/192.168.1.101/tcp/41721"]
      cfg.buddies = @[buddy]
      buddyconfig.saveConfig(cfg)
      let before = buddyconfig.loadConfig()

      discard post("/config", %*{
        "folders": [{"name": "docs", "path": testDir, "encrypted": true}],
        "buddies": [{"id": "buddy-1", "name": "carol"}],
      })
      let after = buddyconfig.loadConfig()
      check after.folders[0].id == before.folders[0].id
      check after.folders[0].folderKey == before.folders[0].folderKey
      check after.buddies[0].storagePath == testDir / "carol"
      check after.buddies[0].addresses == @["/ip4/192.168.1.101/tcp/41721"]

  test "folder names with spaces can be removed":
    withTestDir("control_remove_spaced"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      discard post("/folders", %*{"name": "Okrypterade filer", "path": testDir})
      let response = handleRequest("DELETE /folders/Okrypterade%20filer HTTP/1.1\r\n\r\n")
      check responseStatus(response) == 200
      check buddyconfig.loadConfig().folders.len == 0

  test "a sync request for a folder is queued for the daemon":
    withTestDir("control_sync_request"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      discard post("/folders", %*{"name": "My photos", "path": testDir})
      check responseStatus(handleRequest("POST /sync/My%20photos HTTP/1.1\r\n\r\n")) == 200
      check responseStatus(handleRequest("POST /sync/My%20photos HTTP/1.1\r\n\r\n")) == 200
      check takeSyncRequests() == @["My photos"]
      check takeSyncRequests().len == 0

  test "POST /sync asks for every folder and names the buddies it reaches":
    withTestDir("control_sync_all"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      discard post("/folders", %*{"name": "docs", "path": testDir})
      discard post("/folders", %*{"name": "photos", "path": testDir, "buddies": ["buddy-2"]})
      discard post("/buddies/pair", %*{"buddyId": "buddy-1", "buddyName": "Alice", "code": "a"})
      discard post("/buddies/pair", %*{"buddyId": "buddy-2", "buddyName": "Bob", "code": "b"})
      let response = handleRequest("POST /sync HTTP/1.1\r\n\r\n")
      check responseStatus(response) == 200
      let body = responseJson(response)
      check body["folders"].getInt() == 2
      check body["buddies"].len == 2
      check body["buddies"][0]["name"].getStr() == "Alice"
      check not body["daemonRunning"].getBool()
      check takeSyncRequests() == @["docs", "photos"]

  test "sync request progress reaches GET /sessions":
    withTestDir("control_sync_progress"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      let at = initTime(1_800_000_000, 0)
      writeSyncRequests(@[SyncRequestState(buddyId: "b1", buddyName: "Bob", requestedAt: at,
        updatedAt: at, state: "not found", detail: "not published")])
      let requests = responseJson(handleRequest("GET /sessions HTTP/1.1\r\n\r\n"))["requests"]
      check requests.len == 1
      check requests[0]["state"].getStr() == "not found"
      check requests[0]["buddyName"].getStr() == "Bob"

  test "a sync request for an unknown folder is refused":
    withTestDir("control_sync_unknown"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      check responseStatus(handleRequest("POST /sync/nope HTTP/1.1\r\n\r\n")) == 404
      check takeSyncRequests().len == 0

  test "the daemon's schedule for a buddy reaches GET /buddies":
    withTestDir("control_buddy_schedule"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      # A state.db from before the schedule columns existed.
      let old = open(testDir / "state.db", "", "", "")
      old.exec(sql"CREATE TABLE buddy_state (id TEXT PRIMARY KEY, name TEXT, state TEXT, latency_ms INTEGER, last_activity TEXT)")
      old.close()
      let next = initTime(1_800_000_000, 0)
      writeLiveStatus(@[BuddyStatus(id: "b1", name: "Bob", state: csDisconnected, latencyMs: -1,
        nextSync: next, intervalMinutes: 30, buddyDials: true)], @[])
      let buddy = responseJson(handleRequest("GET /buddies HTTP/1.1\r\n\r\n"))["buddies"][0]
      check buddy["nextSync"].getStr() == next.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      check buddy["intervalMinutes"].getInt() == 30
      check buddy["buddyDials"].getBool()

  test "GET /status names the build":
    withTestDir("control_build"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      let build = responseJson(handleRequest("GET /status HTTP/1.1\r\n\r\n"))["build"]
      check build["version"].getStr() == "0.1.0"
      check build["commit"].getStr().len >= 7
      check build["builtAt"].getStr().endsWith("Z")
      check build["protocolVersion"].getInt() > 0

  test "folder problems and the last sync reach GET /folders":
    withTestDir("control_folder_status"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      # A state.db from before the detail columns existed.
      let old = open(testDir / "state.db", "", "", "")
      old.exec(sql"CREATE TABLE folder_state (name TEXT PRIMARY KEY, total_bytes INTEGER, synced_bytes INTEGER, file_count INTEGER, synced_files INTEGER, status TEXT)")
      old.close()
      discard post("/folders", %*{"name": "docs", "path": testDir})
      let synced = initTime(1_800_000_000, 0)
      writeLiveStatus(@[], @[SyncStatus(folder: "docs", status: "refused",
        detail: "Bob refused it: owned by another machine", lastSync: synced)])
      let folders = responseJson(handleRequest("GET /folders HTTP/1.1\r\n\r\n"))["folders"]
      check folders.len == 1
      let status = folders[0]["status"]
      check status["status"].getStr() == "refused"
      check status["detail"].getStr() == "Bob refused it: owned by another machine"
      check status["lastSync"].getStr() == synced.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

  test "sync sessions are kept in state.db and listed newest first":
    withTestDir("control_sessions"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
      let started = initTime(1_800_000_000, 0)
      writeSessions(@[
        SessionRecord(id: 1, buddyId: "b1", buddyName: "Bob", dialedBy: "us", via: "direct",
          startedAt: started, endedAt: started + initDuration(seconds = 12), outcome: "ok",
          bytesSent: 2048, filesSent: 2, bytesReceived: 10, filesReceived: 1),
        SessionRecord(id: 2, buddyId: "b1", buddyName: "Bob", dialedBy: "buddy", via: "direct",
          startedAt: started + initDuration(seconds = 5), endedAt: started + initDuration(seconds = 5),
          outcome: "turned away"),
      ])
      check readSessions().len == 2
      let sessions = responseJson(handleRequest("GET /sessions HTTP/1.1\r\n\r\n"))["sessions"]
      check sessions.len == 2
      check sessions[0]["outcome"].getStr() == "turned away"
      check sessions[0]["dialedBy"].getStr() == "buddy"
      check sessions[1]["bytesSent"].getInt() == 2048
      check sessions[1]["filesReceived"].getInt() == 1
      check sessions[1]["endedAt"].getStr() == (started + initDuration(seconds = 12)).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

  test "storage totals are reused for a while instead of walked on every request":
    withTestDir("control_storage_cache"):
      initTestConfig(testDir)
      defer:
        delEnv("BUDDYDRIVE_CONFIG_DIR")
        delEnv("BUDDYDRIVE_DATA_DIR")
        storageUsageMaxAge = initDuration(seconds = 60)
      var cfg = buddyconfig.loadConfig()
      var buddy: BuddyInfo
      buddy.id = newBuddyId("bb", "bob")
      buddy.storagePath = testDir / "bob"
      cfg.addBuddy(buddy)
      createDir(testDir / "bob")
      writeFile(testDir / "bob" / "one", "1")

      proc storedFileCount(): int =
        responseJson(handleRequest("GET /storage HTTP/1.1\r\n\r\n"))["storage"][0]["files"].getInt()

      check storedFileCount() == 1
      writeFile(testDir / "bob" / "two", "2")
      check storedFileCount() == 1
      storageUsageMaxAge = initDuration(seconds = 0)
      check storedFileCount() == 2

      # A folder's owner record is not one of the buddy's files; a file of
      # theirs that happens to end the same way is.
      writeFile(testDir / "bob" / "folder-x.owner", "{}")
      createDir(testDir / "bob" / "folder-x")
      writeFile(testDir / "bob" / "folder-x" / "notes.owner", "3")
      check storedFileCount() == 3
