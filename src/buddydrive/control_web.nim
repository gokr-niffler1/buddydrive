import std/strutils

const
  indexHtml* = staticRead("../web/index.html")
  styleCss* = staticRead("../web/style.css")
  appJs* = staticRead("../web/app.js")

  forbiddenResponse* = "HTTP/1.1 403 Forbidden\r\n" &
    "Content-Type: text/plain\r\n" &
    "Content-Length: 9\r\n" &
    "Connection: close\r\n\r\n" &
    "Forbidden"

proc httpResponse(body: string, contentType: string): string =
  "HTTP/1.1 200 OK\r\n" &
    "Content-Type: " & contentType & "\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" &
    body

proc isLocalhost*(address: string): bool =
  address.startsWith("127.") or address == "::1"

proc webSecret*(buddyUuid: string): string =
  buddyUuid.replace("-", "").toLowerAscii()[0 ..< 8]

proc extractPath(raw: string): string =
  let lineEnd = raw.find('\r')
  let requestLine = if lineEnd > 0: raw[0 ..< lineEnd] else: raw
  let parts = requestLine.split(' ')
  if parts.len >= 2: parts[1] else: ""

proc stripSecretPrefix(path: string, secret: string): string =
  let prefix = "/w/" & secret & "/"
  if path.startsWith(prefix):
    return path[prefix.len - 1 .. ^1]
  let prefixNoTrail = "/w/" & secret
  if path == prefixNoTrail:
    return "/"
  ""

proc lanRootRedirect*(raw: string, buddyUuid: string): string =
  ## The page loads its assets by relative path, so /w/<secret> must become
  ## /w/<secret>/ or they resolve outside the secret prefix.
  let location = "/w/" & webSecret(buddyUuid)
  if extractPath(raw) != location:
    return ""
  "HTTP/1.1 301 Moved Permanently\r\n" &
    "Location: " & location & "/\r\n" &
    "Content-Length: 0\r\n" &
    "Connection: close\r\n\r\n"

proc rewriteLanRequest*(raw: string, buddyUuid: string): string =
  let secret = webSecret(buddyUuid)
  let path = extractPath(raw)
  let stripped = stripSecretPrefix(path, secret)
  if stripped.len == 0:
    return ""
  raw.replace(" " & path & " ", " " & stripped & " ")

proc serveWebRequest*(raw: string): string =
  let path = extractPath(raw)
  case path
  of "/", "/index.html": httpResponse(indexHtml, "text/html; charset=utf-8")
  of "/style.css": httpResponse(styleCss, "text/css; charset=utf-8")
  of "/app.js": httpResponse(appJs, "application/javascript; charset=utf-8")
  else: ""
