# AGENTS.md - BuddyDrive Development Guide

## Project Overview

BuddyDrive is a P2P encrypted folder sync tool written in Nim. It syncs folders with 1-2 buddies across the internet, bypassing NATs and firewalls. It includes a CLI daemon, a web GUI (embedded in the daemon), a GTK4 GUI, and a relay server.

## Build Commands

```bash
# Build CLI (default debug)
nimble build

# Build CLI (release)
nimble build -d:release
# or: nim c -d:release src/buddydrive.nim

# Build GTK4 GUI (debug)
nimble gui

# Build GTK4 GUI (release)
nimble gui_release

# Install GTK4 GUI with desktop integration
nimble install_gui

# Install icons
nimble icons

# Run all tests
nimble test

# Run unit tests only
nimble testUnit

# Run integration tests only
nimble testIntegration

# Run a specific test suite
nimble testConfig
nimble testCrypto
nimble testRecovery
nimble testPolicy
nimble testAddrs
nimble testScanner
nimble testIndex
nimble testMessages
nimble testConfigSync
nimble testControl
nimble testControlWeb
nimble testRawRelay
nimble testPairing
nimble testTransfer
nimble testCli

# Build Debian package
make deb
```

## Lint / Typecheck

There is no separate lint or typecheck command. The Nim compiler performs full type checking during build. Always run `nimble build` after making changes to verify correctness.

## Key Build Flags

- `--mm:arc` or `--mm:orc` — required by the `curly` HTTP library
- `--threads:on` — required by `curly`
- `-d:ssl` — enabled in config.nims
- `-d:gtk4` — enable GTK4 GUI build
- `-d:chronicles_log_level=ERROR` — set in config.nims

## Architecture

### Source Layout

```
src/
├── buddydrive.nim              # CLI entry point, command dispatch
├── buddydrive_gui.nim          # GTK4 GUI entry point
├── web/                        # Web GUI assets (embedded via staticRead)
│   ├── index.html
│   ├── style.css
│   └── app.js
└── buddydrive/
    ├── types.nim               # Core types (AppConfig, BuddyId, FolderConfig, RecoveryConfig)
    ├── config.nim              # TOML config read/write (~/.buddydrive/config.toml)
    ├── crypto.nim              # libsodium encryption (XSalsa20-Poly1305)
    ├── recovery.nim            # BIP39 mnemonic (standard generation + SHA-256 checksum), Argon2i key derivation, config encrypt/decrypt
    ├── cli.nim                 # CLI subcommand handlers
    ├── daemon.nim              # Background sync daemon, discovery loop
    ├── control.nim             # REST API on localhost:17521, state.db management
    ├── control_web.nim         # Web GUI serving (staticRead + LAN secret auth)
    ├── logutils.nim            # Logging setup
    ├── nat.nim                 # NAT traversal (UPnP, CGNAT detection)
    ├── p2p/
    │   ├── node.nim            # libp2p node setup
    │   ├── addrs.nim           # Address selection: what to publish, what to dial
    │   ├── discovery.nim       # Relay API discovery: per-buddy record keys, owner token (X-BD-Discovery-Token)
    │   ├── protocol.nim        # BuddyDrive sync protocol
    │   ├── pairing.nim         # Buddy pairing handshake
    │   ├── messages.nim        # Protocol message types
    │   ├── rawrelay.nim        # Relay client for NAT fallback
    │   └── synchandler.nim     # Sync handler
    └── sync/
        ├── scanner.nim         # Polling file scanner, chunk I/O, .buddytmp atomic writes
        ├── index.nim           # SQLite file index
        ├── transfer.nim        # Chunked file transfer (64KB, LZ4 compression)
        ├── session.nim         # Sync sessions (owner round + storage round per buddy)
        ├── storage.nim         # Storage side: a buddy's folders kept on our disk
        ├── policy.nim          # Per-buddy sync time window
        └── config_sync.nim     # Config sync to relay/buddies, recovery logic
```

### Relay Server

The relay server lives in a separate repository: https://github.com/gokr/buddydrive-relay

### Other Directories

```
icons/                          # Application icons (48x48 through 512x512)
wordlists/                      # BIP39 English wordlist + name generation lists
  ├── bip39_english.txt
  ├── adjectives.txt
  └── nouns.txt
debian/                         # Debian packaging (control, rules, service, manpages)
website/                        # Static website content (docs, features, security, how-it-works)
tests/
  ├── testutils.nim            # Shared test helpers (withTestDir, useIsolatedDataDir, etc.)
  ├── support/*.nim            # Test harness, in-process relay and KV API stubs
  ├── unit/*/*.nim             # Unit tests
  └── integration/*.nim        # Integration tests
```

### Config & Data

- `~/.buddydrive/config.toml` — Static config (identity, folders, buddies, recovery)
- `~/.buddydrive/state.db` — Runtime state (SQLite): tables `runtime_status`, `buddy_state`, `folder_state`, `cached_buddy_addrs`
- `~/.buddydrive/index.db` — File metadata index (SQLite)
- `~/.buddydrive/port` — Control API port (written after daemon startup)
- `~/.buddydrive/buddydrive.log` — Log file

### GUI / Control API

- **Web GUI**: Served from the daemon via `control_web.nim` using `staticRead` to embed `src/web/` assets. No external files needed.
- **GTK4 GUI**: Direct GTK4 (not Owlkettle). Reads control API port from `~/.buddydrive/port`.
- **Control API**: REST server on `0.0.0.0:17521` (default). Localhost: no auth. LAN: secret path `/w/<secret>/` derived from buddy UUID.
- Dynamic daemon state lives in `state.db`; static configuration lives in `config.toml`
- GTK4 text entry widgets use `gtk_editable_get_text` (not `gtk_entry_get_text`)
- Cdecl callbacks cannot capture locals; use `userData` with allocated strings

### Constants

- Default P2P port: `41721` (defined in `types.nim`)
- Default control port: `17521` (defined in `control.nim`)
- Scheduler tick: 1 minute (`BuddyScheduleTick` in `daemon.nim`); each buddy is dialed per its own sync interval (default 5m until first contact, then 30m; `policy.nim`)
- Discovery record TTL: 6h (server-side), re-published every 4h
- File chunk size: 64KB
- Transfer files use LZ4 compression when it reduces size

## Conventions

### Nim Style

- No comments in code unless explicitly requested
- Follow existing patterns in neighboring files
- Use `logutils` for logging (not raw `echo` except in CLI handlers)
- Use `parsetoml` for TOML parsing (not `toml-serialization`)
- Use `results` for error handling (`Result` type, not exceptions for expected failures)

### Async / GC Safety

- Chronos async procs enforce GC-safety — non-GC-safe calls (e.g., `parsetoml.parseFile`) must be wrapped with `{.cast(gcsafe).}:`
- Chronos async procs enforce exception tracking — calls that can raise `SodiumError` must be wrapped in `try/except`
- The control server runs synchronous HTTP in a dedicated thread
- SQLite access via `db_connector/db_sqlite` (bundled with Nim 2.2.8+). Both databases set `PRAGMA busy_timeout = 5000`: the control thread reads `state.db` while the daemon writes it
- Chronos async requires `{.cast(gcsafe).}` for cross-thread calls

### Encryption

- libsodium via `libsodium/sodium` and `libsodium/sodium_sizes` imports
- `crypto_secretbox_easy` / `crypto_secretbox_open_easy` for config and file encryption (XSalsa20-Poly1305)
- `crypto_pwhash` for key derivation from passwords/mnemonics (Argon2i; moderate tier for recovery: `opslimit_moderate`, `memlimit_moderate`)
- `crypto_generichash` for key derivation and content hashing (returns `seq[byte]`, not `string`)
- `crypto_generichash` signature: `crypto_generichash(data: string, hashlen: int, key: string = ""): seq[byte]`
- `crypto_pwhash` signature: `crypto_pwhash(passwd: string, salt: openArray[byte], outlen: Natural, alg, opslimit, memlimit): seq[byte]`
- `crypto_generichash` returns `seq[byte]` not `string`, so assignment to `array[32, byte]` requires explicit `byte()` casts
- **Streaming hash**: use `crypto_generichash_init/update/final` for large files — never read full file into memory
- **Deterministic path encryption**: derive nonce from `folderKey + "/path/" + plaintextPath` so same path always encrypts to same ciphertext (enables move detection)
- **Chunk encryption with random nonces**: each chunk gets a random nonce (24 bytes, prepended to ciphertext). Deterministic nonces are unsafe for content — same (file, offset) may have different plaintext across versions, causing nonce reuse.
- **Folder key from stable ID**: `folderKey = generichash(masterKey + "/folder/" + folderId)`. `folderId` is a UUID, not the folder name, so renaming doesn't orphan remote data.

## Current Sync Model

The new sync model is now **largely implemented**. See `docs/PLAN.md` for the full design and remaining work. Key implemented features:

- **Encrypted backup model**: files stored encrypted on buddy's machine (filenames + content). Buddy is storage, not co-author. Sync is never a mirror between same-named folders.
- **Per-buddy storage root**: `[[buddies]] storage_path`, else `<storage_base_path or ~/.buddydrive/storage>/<buddy-uuid>`. Each shared folder lives in `<root>/<folder-id>/` (see `buddyStorageRoot` in `config.nim`, `sync/storage.nim`).
- **Opaque blobs**: encrypted folders are stored as `<hh>/<hash>.blob` (sealed chunk frames as sent) plus a `.meta` JSON sidecar. Unencrypted folders are stored as plain files.
- **Paths from a buddy go through `safeJoin`** (`scanner.nim`) before touching disk. It also refuses `.buddytmp` names, and `applyFileMetadata` never follows a symlink: in unencrypted storage a buddy's symlink is a real link.
- **Per-buddy sync_window + sync_interval**: `sync_window = "HH:MM-HH:MM"` (empty = any time; legacy `sync_time = "HH:MM"` is read as ±15 min) and `sync_interval = "30m"/"2h"` (empty = 5m until first contact, then 30m). Control when to initiate, not when to accept. A buddy that dials us is still looked up every 10 min (`RelayStandbyMinutes`) so relay rendezvous keeps working.
- **Build ID**: `version.nim` takes the version from `buddydrive.nimble` and the git commit (`-dirty` if modified) at compile time; set `-d:buildCommit=<id>` where there is no git checkout. Printed at daemon start and returned by `GET /status` as `build`, with the wire protocol version.
- **GUI locale**: `[gui] locale` (BCP 47, e.g. `sv-SE`; empty = browser's) set in the web GUI Settings. The API always sends UTC ISO 8601; `app.js` formats dates, sizes, counts and relative times with `Intl` in that locale (`makeFormatters`).
- **GUI sync requests**: `POST /sync` (all) and `POST /sync/<folder>` queue a request; the daemon's progress per buddy (`SyncRequestState`) is written to `state.db` `sync_requests` and returned by `GET /sessions` as `requests`.
- **Always accept incoming**: sync time controls initiation only. Incoming connections from known buddies are always accepted.
- **Deterministic initiator**: CGNAT side initiates (dials the public side). If both public, lower UUID initiates.
- **Streaming blake2b hash**: `crypto_generichash_init/update/final` — 64KB chunks, never full file in memory.
- **Deterministic path encryption**: same path → same encrypted path. Enables move detection.
- **Random content nonces**: each chunk encrypted with random nonce (prepended). Same file encrypted twice produces different ciphertext — prevents nonce reuse.
- **Content-hash-based sync**: owner sends its blake2b content hash to the storage buddy, keyed with the folder key for encrypted folders (`keyedContentHash`, `wireHash` in `transfer.nim`) so the buddy cannot match it against known files. Detects changes, moves, and deletes. Older backups with plain hashes are rekeyed in place with `msgRehash`, not re-sent.
- **Owner-authoritative moves**: A tells B "rename X to Y". B does not infer moves from ciphertext identity.
- **Delete propagation**: `msgFileDelete` is sent and handled.
- **Hash verification on restore**: `verifyRestoredFile` re-scans and checks hash after write.
- **SQLite index is cache**: both sides maintain indexes for performance, but restore only needs the folder key + buddy's filesystem.
- **Index rows are keyed by folder id + normalized path** (`indexKey` in `transfer.nim`), so a rename keeps a folder's tombstones and a new path starts afresh (stored files are restored there, not deleted). Rows under the old `name|path` key are taken over on first use. Writes that deletes depend on (`cacheScannedFile`, delete confirmations, `removeFile`) raise instead of failing silently.
- **Restore flow**: recover config from relay → connect to buddy → list encrypted paths → decrypt paths → request missing files → verify hashes → rebuild index
- **Discovery records are per buddy**: key = pairing code + publishing buddy's id; writes carry a stable owner token so a restarted buddy can replace its record (needs the matching buddydrive-relay).
- **Discovery publishes public addresses only** (plus `announce_addr`). LAN buddies are reached via per-buddy `addresses` in config, dialed first.
- **Pairing codes** come from libsodium's CSPRNG (`generatePairingCode` in `crypto.nim`), never `std/random`.
- **Create folders with `newSyncFolder`** (`config.nim`), never bare `newFolderConfig`: it sets the stable id and the folder key. An encrypted folder without a key is skipped by sync, and the daemon repairs such folders at startup (`ensureFolderIdentities`).
- **One owning machine per stored folder**: owners send `config.machineId()` (data dir, not config.toml); the storage side records it in `<buddy root>/<folder dir>.owner` and answers another machine with `msgFolderRefused`, unless it takes over (`requestTakeover`, set by `recover` and `buddydrive takeover`, cleared per buddy after a successful session).
- **Wire protocol version 7** (`ProtocolVersion` in `messages.nim`): older peers are rejected at the handshake.

### Remaining Work

- **Buddy-backed config fetch**: `syncConfigToBuddy()` and `fetchConfigFromBuddy()` are not implemented yet. Recovery works via relay path only.
- **Connection reuse**: check for existing transport connections before new dial — not yet implemented.
- **Connection upgrade**: replace relay with direct when possible — not yet implemented.
- **Long-lived CGNAT connections**: keepalive and prompt redial — not yet implemented.
- **`init --with-recovery`**: parsed as CLI flag but does nothing. Use `init` then `setup-recovery`.
- **Large folder listings**: file list exchange uses a single framed message (30MB max). Pagination or streaming deferred.
- **Blocking discovery HTTP**: `publishBuddy`, `findBuddy` and `unpublishBuddy` (`discovery.nim`) call curly synchronously from async code, so an unreachable API stalls the chronos loop for up to 30 s per call. They belong on a worker thread.

### Minor Known Issues

Smaller leftovers from the code review of the multi-buddy-ownership branch. None of them changes the backup model's guarantees; each is a bounded cleanup.

- **`sendBlob` can abort mid-stream without an ack** (`sync/storage.nim`): when a frame fails after earlier frames were already sent, it returns false without sending `msgFileAck`, so the owner waits for the 5-minute idle timeout instead of failing fast. Send `newFileAck(false)` on that path, as `receiveBlob` already does.
- **`takeSyncRequests` can leave a `.taken` file** (`control.nim`): if the process stops between `moveFile` and `removeFile`, that file is never read again (the next request still lands in the original path). Clean stale `.taken` files up on startup, or read the requests without the rename.
- **`addFile` still fails silently** (`sync/index.nim`): it uses `tryExec`/`discard`, unlike the other delete-critical writes (`cacheScannedFile`, `removeFile`, `confirmDelete`, `clearDeleteConfirmations`). A dropped row self-heals on the next scan, but make it raise for consistency.
- **Legacy index adoption only matches the folder's current name** (`indexKey`/`legacyIndexKey` in `sync/transfer.nim`): a folder renamed on an older build before upgrading keeps its rows under `oldname|path` and they are never adopted, so its old tombstones are orphaned. Rare; only the new key's `name|path` form is looked for.
- **`writeLiveStatus` has no explicit rollback** (`control.nim`): if a statement fails mid-transaction it relies on the connection closing to roll back, unlike `adoptLegacyRows` (`sync/index.nim`), which rolls back itself. Wrap it in `try/except` with `ROLLBACK` for the same guarantee.
- **Restored symlink metadata is not verified consistently** (`sync/transfer.nim`): `applyFileMetadata` deliberately skips symlinks, but `verifyRestoredFile` still compares `expected.mode` for them; on a platform whose link permissions differ that could fail verification. Skip the mode check when `symlinkTarget` is set.
- **An empty machine id bypasses the one-owner rule** (`sync/storage.nim`): `decideOwnership` accepts a listing whose `ownerMachine` is empty, so a peer whose id cannot be read has no ownership protection. The daemon now logs when its own id is unreadable; consider refusing instead.
- **`saveConfig` races between the daemon and the control thread** (`config.nim`, `control.nim`, `daemon.nim`): both write `config.toml` through the same atomic temp-file + rename, so the file never tears, but a concurrent reload/save can still lose one side's update. Serialize config writes (a lock, or make the daemon the only writer).
- **`connect` and `--daemon` are no-ops** (`cli.nim`): both are still advertised in the help text and in `init`'s output but only print "not implemented" (or are ignored). Implement them or remove them from the docs and CLI.
- **`version.nim` claims `BuildTime` is UTC**: the comment says so, but Nim's `CompileTime` is local time. Convert it to UTC or fix the comment.

### HTTP Client (curly)

- `curly` requires `--mm:arc/orc` and `--threads:on`
- Timeout is passed per-request, not set on client
- `webby/httpheaders` for `emptyHttpHeaders()`
- PUT body: `body: openarray[char] = "".toOpenArray(0, -1)`

### File I/O / Crash Safety

- Files are written to `<path>.buddytmp` first, then `flushFile` + `closeFile` + `moveFile` to final path
- On daemon startup, `cleanupTempFiles` deletes leftover `.buddytmp` files
- Scanner ignores `.buddytmp` files during scans
- Config writes use atomic temp-file + rename (`config.nim`)
- Use `fmReadWriteExisting` (not `fmReadWrite`) for subsequent chunks to avoid truncation

### Config Hot-Reload

- The daemon polls `config.toml` mtime in the discovery loop and reloads on change
- `POST /config/reload` on the control API forces a reload

## Key Dependencies

- **libp2p** — P2P networking, direct transport
- **libsodium** — Encryption, key derivation
- **parsetoml** — TOML parsing (not GC-safe, needs `{.cast(gcsafe).}` in async)
- **chronos** — Async framework
- **curly** — HTTP client (relay API, config sync)
- **db_connector/db_sqlite** — SQLite (bundled with Nim 2.2.8+)
- **results** — Result type for error handling
- **stew** — Utility types used by libp2p
- **uuids** — UUID generation for buddy/folder IDs
- **nat_traversal** — NAT hole punching (UPnP)
- **lz4wrapper** (fork) — LZ4 compression for file chunks
- **nim-zlib** (pinned) — zlib for libp2p; pinned because libp2p declares underspecified version

## Recovery System

See `docs/PLAN.md` for full details. Key points:

- BIP39 12-word mnemonic (standard generation: 128-bit entropy + SHA-256 checksum; Argon2i key derivation instead of PBKDF2)
- Master key derived via Argon2i (moderate tier, 256 MB) then BLAKE2b; stored plaintext in config.toml
- Config encrypted before syncing to relay/buddies
- Public key (Base58, derived via BLAKE2b from master key — not an asymmetric public key) used as relay API config lookup key
- Ed25519 signing keypair derived from master key for relay API authentication (X-BD-Verify-Key, X-BD-Signature headers)
- TiDB Cloud for relay-backed API storage
- Default API URL: `https://api.buddydrive.org`
- Default TCP relay: `relay-eu.buddydrive.org:41722`

## Testing

Tests use `std/unittest` and run through `tests/testrunner.nim`, a small
parallel runner that replaces `testament pattern`:

- `nimble test` — unit and integration suites, in parallel
- `nimble testUnit` / `nimble testIntegration` — one group
- `nimble test<Suite>` — one file or directory
- `nimble testSerial` — the same suites one at a time through testament, for
  bisecting a failure that only shows up in parallel

The runner keeps testament's per-test nimcache layout, so a repeat run only
recompiles what changed, and it compiles and runs several tests at once
(unit: cores-1, integration: 4, because the integration tests bind ports and
drive real daemons). A test that runs longer than `--timeout:` seconds (300 by
default) is killed and reported as a failure instead of hanging the suite.

Used directly:

```
nim c --hints:off -o:testresults/testrunner tests/testrunner.nim
testresults/testrunner pattern "tests/unit/*/*.nim"
testresults/testrunner pattern "tests/unit/session/*.nim" --jobs:4
testresults/testrunner pattern "tests/unit/*/*.nim" --filter:session
testresults/testrunner pattern "tests/integration/*.nim" --verbose
```

Tests have to stay safe to run in parallel: take ports from `freePort()`, which
reserves the number across test processes, never a fixed port; keep state in
`useIsolatedDataDir` or `withTestDir` paths, never in `~/.buddydrive` or a
fixed temp name; and do not assume a sibling test has not run. The runner
builds the `buddydrive` binary that the integration tests shell out to once,
into `testresults/bin/`, and passes the path in `BUDDYDRIVE_TEST_CLI`.

- **Unit tests**: `tests/unit/*/*.nim` — 17 test files covering config, crypto, recovery, messages, policy, scanner, transfer crash safety, control, control_web, rawrelay, index, pairing, types, config_sync, discovery, session, addrs, storage
- **Integration tests**: `tests/integration/*.nim` — 6 test files covering CLI flows, config sync e2e, relay fallback, relay file sync, pairing, direct file sync, daemon shutdown

Integration tests are self-contained: they start their own services in-process
and fail rather than skip. Never reintroduce a "skip on error" wrapper — it hid
a data-loss bug in the sync delta for months.

- `tests/support/test_relay.nim` — TCP relay stand-in; region `local` resolves
  to it. The production relay lives in the buddydrive-relay repository.
- `tests/support/kv_stub.nim` — KV API stand-in (PUT/GET/DELETE `/kv/<key>`),
  including real Ed25519 signature verification. Runs on its own thread because
  curly blocks the caller.

Test environment variables:
- `BUDDYDRIVE_KV_API_URL` — test against a real API instead of the stub
- `BUDDYDRIVE_DATA_DIR` / `BUDDYDRIVE_CONFIG_DIR` — set per test process by
  `useIsolatedDataDir`

Test utilities (`tests/testutils.nim`):
- `withTestDir(baseName)` — create/cleanup temp directory
- `withTestFile(baseName, content)` — create/cleanup temp file
- `useIsolatedDataDir(name)` — fresh config/index dir, so stale index rows never
  leak between runs (they drive move/delete detection)
- `makeFileInfo()` — create test FileInfo

## Debian Packaging

- `make deb` builds the `.deb` package
- Debian dir contains: control, rules, service unit, postinst, manpages
- Systemd service runs as `buddydrive` user
- Build requires: `debhelper dpkg-dev help2man`
- `make install` supports `DESTDIR` for packaging

## Nim Quirks / Discoveries

- `reversed()` returns `seq[char]` not `string`, so base58 encoding needed manual reversal
- `fmReadWrite` truncates existing files; use `fmReadWriteExisting` for subsequent chunks
- Nim's `std/options` needed for `Option`/`some`/`none`
- `toml-serialization` is NOT used — use `parsetoml` only
