import std/[strutils, unittest]
import ../../../src/buddydrive/control_web

proc hasPrefix(value: string, prefix: string): bool =
  value.len >= prefix.len and value[0 ..< prefix.len] == prefix

suite "control_web helpers":
  test "isLocalhost accepts loopback addresses":
    check isLocalhost("127.0.0.1")
    check isLocalhost("127.1.2.3")
    check isLocalhost("::1")
    check not isLocalhost("192.168.1.10")

  test "webSecret uses first 8 lowercase hex chars without dashes":
    check webSecret("ABCD1234-5678-90AB-CDEF-1234567890AB") == "abcd1234"

  test "rewriteLanRequest rewrites valid secret path":
    let raw = "GET /w/abcd1234/folders HTTP/1.1\r\nHost: example\r\n\r\n"
    let rewritten = rewriteLanRequest(raw, "abcd1234-5678-90ab-cdef-1234567890ab")
    check hasPrefix(rewritten, "GET /folders HTTP/1.1")

  test "rewriteLanRequest maps secret root to slash":
    let raw = "GET /w/abcd1234 HTTP/1.1\r\nHost: example\r\n\r\n"
    let rewritten = rewriteLanRequest(raw, "abcd1234-5678-90ab-cdef-1234567890ab")
    check hasPrefix(rewritten, "GET / HTTP/1.1")

  test "the secret root without a slash redirects to it with one":
    let uuid = "abcd1234-5678-90ab-cdef-1234567890ab"
    let redirect = lanRootRedirect("GET /w/abcd1234 HTTP/1.1\r\nHost: example\r\n\r\n", uuid)
    check hasPrefix(redirect, "HTTP/1.1 301")
    check "Location: /w/abcd1234/\r\n" in redirect
    check lanRootRedirect("GET /w/abcd1234/ HTTP/1.1\r\n\r\n", uuid) == ""
    check lanRootRedirect("GET /w/wrong999 HTTP/1.1\r\n\r\n", uuid) == ""

  test "rewriteLanRequest rejects wrong secret":
    let raw = "GET /w/wrong999/folders HTTP/1.1\r\nHost: example\r\n\r\n"
    check rewriteLanRequest(raw, "abcd1234-5678-90ab-cdef-1234567890ab") == ""

  test "serveWebRequest serves known assets":
    check hasPrefix(serveWebRequest("GET / HTTP/1.1\r\n\r\n"), "HTTP/1.1 200 OK")
    check hasPrefix(serveWebRequest("GET /style.css HTTP/1.1\r\n\r\n"), "HTTP/1.1 200 OK")
    check hasPrefix(serveWebRequest("GET /app.js HTTP/1.1\r\n\r\n"), "HTTP/1.1 200 OK")

  test "serveWebRequest returns empty for unknown path":
    check serveWebRequest("GET /missing HTTP/1.1\r\n\r\n") == ""
