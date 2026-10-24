## In-process stand-in for the relay's KV API (PUT/GET/DELETE /kv/<key>).
##
## Runs a blocking HTTP/1.1 server on its own thread, because the client side
## (curly/libcurl) blocks the calling thread and would otherwise deadlock with
## anything served from the same event loop.
##
## Signatures are verified exactly as the real service does, so the canonical
## string in sync/config_sync.nim stays covered by the e2e test.

import std/[locks, nativesockets, net, os, strutils, tables]
import libsodium/sodium

type
  KvStub* = ref object
    port*: int

var
  storeLock: Lock
  store: Table[string, string]
  versions: Table[string, int64]
  running: bool
  serverThread: Thread[int]

storeLock.initLock()

proc canonicalKvMutation(httpMethod, lookupKey, verifyKeyHex, body: string, version, timestamp: int64): string =
  httpMethod.toUpperAscii() & "\n" & lookupKey & "\n" & verifyKeyHex & "\n" &
    $version & "\n" & $timestamp & "\n" & body

proc hexToBinary(hex: string): string =
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = chr(parseHexInt(hex[i * 2 .. i * 2 + 1]))

proc signatureValid(httpMethod, key, body: string, headers: Table[string, string]): bool =
  let verifyKeyHex = headers.getOrDefault("x-bd-verify-key")
  let signatureHex = headers.getOrDefault("x-bd-signature")
  let versionStr = headers.getOrDefault("x-bd-version")
  let timestampStr = headers.getOrDefault("x-bd-timestamp")
  if verifyKeyHex.len == 0 or signatureHex.len == 0 or
      versionStr.len == 0 or timestampStr.len == 0:
    return false

  var version, timestamp: int64
  try:
    version = parseBiggestInt(versionStr)
    timestamp = parseBiggestInt(timestampStr)
  except ValueError:
    return false

  let canonical = canonicalKvMutation(httpMethod, key, verifyKeyHex, body, version, timestamp)
  try:
    # Raises when the signature does not check out.
    crypto_sign_verify_detached(hexToBinary(verifyKeyHex), canonical, hexToBinary(signatureHex))
  except CatchableError:
    return false

  # Replays of an older version are rejected, matching the real service.
  withLock storeLock:
    let previous = versions.getOrDefault(key, 0'i64)
    if version < previous:
      return false
    versions[key] = version
  true

proc respond(client: Socket, status: string, body = "") =
  var response = "HTTP/1.1 " & status & "\r\n"
  response.add("Content-Length: " & $body.len & "\r\n")
  response.add("Connection: close\r\n\r\n")
  response.add(body)
  try:
    client.send(response)
  except CatchableError:
    discard

proc handleRequest(client: Socket) =
  var requestLine = ""
  client.readLine(requestLine)
  let parts = requestLine.splitWhitespace()
  if parts.len < 2:
    respond(client, "400 Bad Request")
    return

  let httpMethod = parts[0].toUpperAscii()
  let path = parts[1]

  var headers = initTable[string, string]()
  while true:
    var line = ""
    client.readLine(line)
    if line.len == 0 or line == "\r\n":
      break
    let sep = line.find(':')
    if sep > 0:
      headers[line[0 ..< sep].strip().toLowerAscii()] = line[sep + 1 .. ^1].strip()

  var body = ""
  let contentLength = try:
      parseInt(headers.getOrDefault("content-length", "0"))
    except ValueError:
      0
  if contentLength > 0:
    body = client.recv(contentLength, timeout = 5000)

  if path.startsWith("/discovery/"):
    # Discovery records, guarded like the real API: a stored token must match
    # to replace or delete a live record, and without one the X-HMAC header
    # must. The stub cannot verify the HMAC itself, only compare it.
    let recordKey = "discovery:" & path[11 .. ^1]
    let authKey = "discovery-auth:" & path[11 .. ^1]
    let hmac = headers.getOrDefault("x-hmac", "")
    let token = headers.getOrDefault("x-bd-discovery-token", "")
    proc allowed(storedAuth: string): bool =
      if storedAuth.len == 0:
        return false
      let parts = storedAuth.split('|', 1)
      if parts[1].len > 0:
        token.len > 0 and token == parts[1]
      else:
        parts[0] == hmac
    case httpMethod
    of "PUT":
      var ok = false
      withLock storeLock:
        ok = recordKey notin store or allowed(store.getOrDefault(authKey, ""))
        if ok:
          store[recordKey] = body
          store[authKey] = hmac & "|" & token
      if ok:
        respond(client, "201 Created")
      else:
        respond(client, "401 Unauthorized")
    of "GET":
      var value = ""
      var found = false
      withLock storeLock:
        found = recordKey in store
        if found:
          value = store[recordKey]
      if found:
        respond(client, "200 OK", value)
      else:
        respond(client, "404 Not Found")
    of "DELETE":
      var ok = false
      withLock storeLock:
        ok = recordKey in store and allowed(store.getOrDefault(authKey, ""))
        if ok:
          store.del(recordKey)
          store.del(authKey)
      if ok:
        respond(client, "204 No Content")
      else:
        respond(client, "404 Not Found")
    else:
      respond(client, "405 Method Not Allowed")
    return

  if not path.startsWith("/kv/"):
    respond(client, "404 Not Found")
    return

  let key = path[4 .. ^1]

  case httpMethod
  of "PUT":
    if not signatureValid("PUT", key, body, headers):
      respond(client, "403 Forbidden")
      return
    withLock storeLock:
      store[key] = body
    respond(client, "200 OK")
  of "GET":
    var value = ""
    var found = false
    withLock storeLock:
      found = key in store
      if found:
        value = store[key]
    if found:
      respond(client, "200 OK", value)
    else:
      respond(client, "404 Not Found")
  of "DELETE":
    if not signatureValid("DELETE", key, "", headers):
      respond(client, "403 Forbidden")
      return
    withLock storeLock:
      store.del(key)
    respond(client, "200 OK")
  else:
    respond(client, "405 Method Not Allowed")

proc serve(port: int) {.thread.} =
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(port), "127.0.0.1")
  server.listen()

  while true:
    var readable = @[server.getFd()]
    if selectRead(readable, 200) <= 0:
      if not running:
        break
      continue

    var client: Socket
    try:
      server.accept(client)
    except CatchableError:
      continue

    try:
      # Shared state is only touched under storeLock.
      {.cast(gcsafe).}:
        handleRequest(client)
    except CatchableError:
      discard
    finally:
      client.close()

  server.close()

proc startKvStub*(port: int): KvStub =
  ## Starts the stub and waits until it accepts connections.
  withLock storeLock:
    store.clear()
    versions.clear()
  running = true
  createThread(serverThread, serve, port)

  for _ in 0 ..< 50:
    try:
      let probe = newSocket()
      defer: probe.close()
      probe.connect("127.0.0.1", Port(port))
      return KvStub(port: port)
    except OSError:
      sleep(100)
  raise newException(IOError, "KV stub did not start on port " & $port)

proc url*(stub: KvStub): string =
  "http://127.0.0.1:" & $stub.port

proc stop*(stub: KvStub) =
  running = false
  joinThread(serverThread)
