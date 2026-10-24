import std/[json, os, strutils, unittest]
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

  test "POST /sync/ triggers sync endpoint":
    let resp = handleRequest("POST /sync/photos HTTP/1.1\r\n\r\n")
    check "200" in resp

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
