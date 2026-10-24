# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Core daemon and CLI built on libp2p: `init`, `add-folder`, `add-buddy` with
  pairing codes, `start`, and related subcommands, backed by TOML configuration.
- Buddy pairing protocol and encrypted file sync infrastructure, with
  deterministic initiator selection, UPnP attempts, and relay fallback when
  direct connections fail.
- Encrypted backup of synced files (filenames and content) on the buddy's
  machine, using deterministic path encryption for move detection and random
  content nonces.
- Content-hashed sync with streaming Blake2b hashing, move and delete
  detection, and re-sync of files that exist on the buddy but are missing
  locally (verified by hash).
- Recovery system: 12-word BIP39 recovery phrase with SHA-256 checksum
  (validated against the official BIP39 test vectors), Ed25519 master key
  derived from the mnemonic via Argon2i, and encrypted config sync to the
  relay and buddies. New CLI commands: `setup-recovery`, `recover`,
  `sync-config`, `export-recovery`.
- Crash-safe file receiving: incoming files are written to `.buddytmp` temp
  files, fsynced, then atomically renamed; leftover temp files are cleaned up
  on daemon startup.
- Folder policies: append-only mode that prevents remote overwrites of
  existing local files (including re-sync when the local hash differs from
  the remote, catching corrupt or partial files), and a per-folder encryption
  flag.
- Web-based admin GUI served from the daemon's control server, with
  LAN secret-path authentication and runtime config reload.
- GTK4 desktop GUI (Linux) for monitoring and configuration.
- Daemon control server with SQLite state and a REST API, including recovery
  and restore endpoints, plus a dedicated storage base path for incoming
  buddy data.
- Testament-based test suite with unit and integration tests covering crypto,
  pairing, discovery, sync, crash safety, and relay/KV integration.
- Relay server KV-store API with HMAC-authenticated discovery records,
  a `/relays/<region>` endpoint for per-region TCP relay addresses, packaged
  EU CIDR snapshots, and abuse hardening.
- Per-buddy storage: each buddy's shared folders are kept in a storage folder
  of their own (`storage_path`, default
  `~/.buddydrive/storage/<buddy-id>`), one directory per folder id, so
  same-named folders no longer collide.
- Encrypted folders are held at the buddy as opaque blobs plus a `.meta`
  sidecar, with blob names hashed from the encrypted path, so nothing stored
  reveals the owner's file names or symlink targets. Unencrypted folders are
  stored as ordinary files.
- Folder ownership: each installation has a machine id (kept in the data
  directory, not in `config.toml`) and only one machine may own a folder at a
  given buddy. `buddydrive recover` and the new `buddydrive takeover` command
  claim ownership on the next sync; any other machine is answered with
  `msgFolderRefused` instead of overwriting the backup.
- Delete confirmations: a deleted file's tombstone is held in a
  `delete_confirmations` table until every buddy of the folder has confirmed
  the delete, and cleared if the file comes back.
- Web GUI sync activity: the running session with live counts, the last
  session, turned-away dials, per-buddy totals and the last 30 sessions, kept
  in `state.db` across restarts and served at `GET /sessions`. Per-folder
  status shows synced, skipped, refused, failed or syncing, with the reason
  and last sync time.
- Self-contained integration tests: an in-process TCP relay stand-in, a KV API
  stub that verifies Ed25519 signatures, and an isolated config and index
  directory per test process, plus `docs/architecture.md`.

### Changed

- Per-buddy sync window and interval, set per buddy from the CLI or the web
  Pair dialog. A buddy's sync time controls only when this side initiates;
  incoming connections from known buddies are always accepted. The dialing
  interval is 5 minutes until first contact and 30 minutes afterwards.
- Pairing leaves both buddies with one shared code: `add-buddy
  --generate-code --id <buddy-id>` writes the code for that buddy, and codes
  are generated from libsodium's CSPRNG. Each buddy of a pair publishes its
  discovery record under the pairing code plus its own id, and writes carry an
  owner token so a restarted buddy can replace its own record.
- Known buddy `addresses` in the config are dialed first, ahead of discovered
  addresses. LAN addresses are no longer published to the relay.
- The web GUI can edit folders and choose which buddies they are shared with,
  shows per-buddy storage and sync times, and its Sync button now queues a
  real sync request that the daemon picks up within two seconds, ignoring sync
  time and which side normally dials. The obsolete global "Sync Window"
  settings are gone.
- **Breaking:** wire protocol version 6 and a new discovery key format, so both
  buddies must run this build; older peers are rejected at the handshake.
  Stored recovery `public_key` values in the old short format must be
  regenerated with `setup-recovery` (no migration, as there are no users yet).
- `buddydrive stop` now actually stops the daemon, and Ctrl+C and SIGTERM shut
  down cleanly, unpublishing the discovery record and removing the UPnP
  mapping.
- Peer discovery now uses the relay KV store instead of KadDHT: buddy
  addresses are published and looked up via pairing-code-derived,
  HMAC-authenticated records with a 6-hour TTL, and last-known addresses are
  cached in `state.db` for graceful degradation. The discovery interval moved
  from 15 seconds to 10 minutes.
- The relay server was moved to the separate
  [buddydrive-relay](https://github.com/gokr/buddydrive-relay) repository and
  removed from this one.
- `relayBaseUrl` was renamed to `apiBaseUrl` throughout the config, CLI, and
  API, with `https://api.buddydrive.org` as the default when unset.
- The relay TCP port changed from 19447 to 41722.
- Key derivation was upgraded from the Argon2i interactive tier (64 MB) to the
  moderate tier (256 MB) for stronger GPU/ASIC resistance.
- A single master key derived from the recovery phrase is now used for all
  folders, replacing per-folder keys.
- Documentation was consolidated under `docs/`, the website is deployed via
  GitHub Pages, and Debian packaging gained man pages, tmpfiles configuration,
  and a postinst script. `docs/architecture.md` was added, and the website
  content was brought up to date with pairing, `stop` and `takeover`.

### Fixed

- Double-nonce bug in `encrypt`/`decrypt` that produced a corrupted
  nonce-prefixed ciphertext and broke decryption.
- Crash when mounting the pairing protocol handler on an already-started
  libp2p switch.
- GTK settings dialog not showing saved values, and header overflow on mobile.
- Daemon startup error handling, and a case where a file was moved even though
  `flushAndClose` had failed.
- DNS relay resolution: `/dns4/` and `/dns6/` multiaddresses are now resolved
  to IP addresses before dialing, as the raw TCP transport requires wire
  addresses.
- macOS build and runtime: `libsodium.dylib` loading and the missing
  `liblz4-dev` dependency. `/opt/homebrew/lib` is now included in the link
  path so Homebrew-installed libraries are found.
- Sync no longer deletes files that exist on only one side. A remote path is
  deleted only when the index shows the local side previously held it;
  anything never seen locally is pulled instead. Index rows for files that
  disappeared from disk are retained, and pruning moved to
  `pruneIndexOfMissingFiles` after deletions have propagated, so the worst case
  for a failed session is a deleted file reappearing rather than a live file
  being lost. `deleteLocalFile` now also refuses on append-only folders, which
  previously blocked only overwrites.
- Sync sessions end with an explicit `msgSessionEnd` exchange in a fixed order,
  so a relay cannot tear down the connection while a peer still has data in
  flight and truncate the final stream, which used to report a failed sync for
  a transfer that had completed. `msgSessionEnd` is appended to `MessageKind`
  so existing kind byte values are unchanged; older buddies incur a timeout.
- `buddydrive recover` distinguishes "no config is stored for this recovery
  phrase" from "the config service could not be reached" instead of treating
  every non-200 response as a missing backup. `fetchConfigFromRelayChecked`
  reports `fcFound`, `fcMissing` or `fcUnavailable`.
- Deletes reach every buddy. A tombstone was dropped after the first
  successful session, so a second buddy's copy looked new and the file was
  restored from it.
- A finished session left its connection marked ready, so the dialing side
  never dialed that buddy again for the rest of the daemon's run. Each
  connection now carries one session and is dropped afterwards, and a buddy
  dialing in during a running session is turned away instead of the running
  session being closed.
- Incoming libp2p connections were closed as soon as the handler returned,
  cutting every session short; the session now runs inside the handler. Every
  point where a session stops now logs why.
- Discovery records carried unparseable addresses (a `$` without the
  multiaddress import), and both buddies of a pair wrote to and read back the
  same record.
- `base58Encode` only encoded the last 8 bytes of its input; keys are now full
  length (43-44 characters).
- Folders created from the web or GTK GUI had no `folder_key`, so "encrypted"
  folders went out in plaintext. All creation now goes through
  `newSyncFolder`, and the daemon repairs keyless folders at startup.
- A folder that could not be fully read (for example an unplugged disk) used
  to scan as empty and delete the whole backup at the buddy; such a folder is
  now skipped for the session instead of failing it.
- Paths from a buddy go through `safeJoin`, so a buddy cannot write outside
  its storage folder through a symlink, and empty files sync correctly.
- The file index is keyed by folder id and path, so a rename keeps its delete
  record. SQLite writes wait for a busy database instead of dropping the
  change, and a delete record is never lost silently.
- Web GUI: the page loads again (duplicate `formatBytes`), dialogs are
  centred, names with spaces work, buddy states read connected or
  disconnected, and timestamps no longer drift by the timezone offset.
- `start --port N` works, and a folder whose id another folder already uses is
  skipped rather than colliding with it.
