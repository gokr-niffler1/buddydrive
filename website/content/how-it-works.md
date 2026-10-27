---
title: How It Works
---

## Architecture

BuddyDrive uses peer-to-peer networking, relay fallback, and relay-backed config recovery.

```text
┌─────────────────┐                    ┌─────────────────┐
│  Your Machine   │                    │ Buddy's Machine │
│                 │                    │                 │
│  ┌───────────┐  │   direct/relay     │  ┌───────────┐  │
│  │ BuddyDrive│◄─┼───────────────────┼──►│ BuddyDrive│  │
│  └───────────┘  │                    │  └───────────┘  │
│       │         │                    │       │         │
│       ▼         │                    │       ▼         │
│  ┌───────────┐  │                    │  ┌───────────┐  │
│  │  Files    │  │                    │  │  Files    │  │
│  └───────────┘  │                    │  └───────────┘  │
└─────────────────┘                    └─────────────────┘
```

## Components

### Daemon

The daemon runs in the foreground today and contains:

- **libp2p node** - direct transport
- **Discovery service** - relay API buddy lookup
- **Sync manager** - folder scan and sync orchestration
- **Control API** - localhost HTTP API for the GUI
- **SQLite state** - runtime status and file index tracking

### GUI

The GTK4 app shows:

- Buddy connection state
- Folder sync status
- Folder and buddy configuration
- Pairing and control actions

### CLI

The CLI handles:

- Initial setup
- Pairing
- Relay configuration
- Recovery setup and restore
- Manual inspection of config, folders, buddies, and logs

## Networking

### libp2p Stack

BuddyDrive uses libp2p for direct peer communication:

| Layer | Protocol | Purpose |
|-------|----------|---------|
| Transport | TCP | Direct connection |
| Security | Noise | Direct transport encryption |
| Muxer | Yamux | Multiplexing |
| Discovery | Relay API | Find buddy addresses via pairing-code-derived keys |

### Peer Discovery

How two buddies find each other:

1. Each daemon publishes its address record to the relay API at `/discovery/<derived-key>`, where the key is the pairing code **plus the publishing buddy's own id**, so each side of a pair has its own record (HMAC-authenticated, with an `X-BD-Discovery-Token` owner token so a restarted buddy can replace its own)
2. The daemon looks up each configured buddy under *that buddy's* key when the buddy's sync interval is due: every 5 minutes until first contact, then every 30 minutes by default (`buddy-sync-interval` overrides it)
3. It reads the peer ID, advertised public multiaddrs, reachability flag, and sync time from the record. Private LAN addresses are never published
4. Deterministic initiator selection: the side without a public address initiates; if both same reachability, lower buddy UUID initiates
5. It dials a public TCP address directly — or a configured `buddy-addresses` entry first — and falls back to a relay when configured and no direct dial works
6. Cached addresses in `state.db` allow reconnection when the relay is temporarily unavailable

### NAT Traversal

Current connectivity options:

- **Public TCP address** - direct connection when `announce_addr` points to a reachable public address
- **UPnP** - automatic port forwarding attempt when no explicit `announce_addr` is set
- **Relay fallback** - used when `relay_region` is set and both sides store the same buddy `pairing_code`
- **Known addresses** - `buddy-addresses` entries are dialed first, which covers two buddies on one LAN with no public IP and no relay
- **Deterministic initiator** - the side without a public address initiates; if both same reachability, lower buddy UUID initiates
- **Always accept incoming** - incoming connections from known buddies are accepted regardless of sync time

## File Sync

### Change Detection

The sync manager monitors configured folders:

1. Scan files in the folder using streaming blake2b hash (64KB chunks, never full file in memory)
2. Capture path, encrypted path, size, mtime, content hash, mode, and symlink target
3. Compare against the previous index
4. Detect added, modified, deleted, and moved files (move detection via content hash matching)

### Transfer Protocol

File transfer uses a chunked protocol with encryption:

```text
File list exchange → Delta computation (moves, deletes, missing) → Chunked transfer → Hash verification
```

Chunks are sent in 64KB blocks. LZ4 compression is used when it helps. When folder encryption is enabled, chunks are encrypted with random nonces (XSalsa20-Poly1305). Paths are encrypted with deterministic nonces so the same filename always encrypts the same way, which is what lets a rename move the unit of storage instead of re-uploading it.

A session runs per connection: both sides exchange owner folder lists, then take
turns (the buddy with the lower UUID goes first) serving their own folders and
storing the other's. The conversation is strictly alternating because the
transport is unbuffered.

Restored files are hash-verified after write.

### Storage

Each buddy's folders are stored in a storage folder of their own on your disk:
`storage/<buddy-id>/<folder-id>/`. Encrypted folders hold `.blob` frames exactly
as the owner sent them (still sealed) plus `.meta` sidecars holding size, mode,
mtime, content hash and symlink target. Blob names are hashes of the encrypted
path, so the directory listing reveals nothing. Unencrypted folders are stored as
ordinary files.

### Restore Behavior

Restore is just backup in the opposite direction:

1. The owner's index says a path it used to hold is now missing
2. The storage side still has the sealed blob
3. The session requests the missing file, and the storage side streams it back
4. The owner decrypts, writes and hash-verifies it

A file the buddy has and you do not is only *deleted* when your index shows you
held that path before; otherwise it is fetched. That is what makes restore onto
an empty machine pull files down instead of wiping the buddy's copy.

If the destination folder is append-only and already has a file with that name, the local file is kept.

### SQLite State

BuddyDrive keeps runtime and file state in SQLite under `~/.buddydrive/`.

## Recovery Flow

### Setup Recovery

1. `buddydrive setup-recovery` generates 128 bits of random entropy
2. A SHA-256 checksum is computed and the entropy + checksum is encoded as a 12-word BIP39 mnemonic
3. The mnemonic is fed through Argon2i (256 MB memory) to produce a 64-byte seed, then BLAKE2b to produce the 32-byte master key
4. Recovery metadata is stored in `[recovery]` in `config.toml`
5. The serialized config is encrypted with the master key and uploaded to the relay

### Recover On A New Machine

1. `buddydrive recover` asks for the 12-word phrase
2. BuddyDrive derives the same master key (Argon2i + BLAKE2b)
3. It fetches the encrypted config blob from the relay
4. The config is decrypted and saved locally
5. Starting the daemon lets normal sync restore missing files
6. On that sync the new machine becomes the owner of its folders at each buddy; the old machine is refused from then on (`buddydrive takeover` does the same for a config copied by hand)

## Control API

Local HTTP server (default port 17521) for GUI communication. Localhost connections require no authentication; LAN connections must use a secret path prefix `/w/<secret>/`.

| Endpoint | Purpose |
|----------|---------|
| GET /status | Runtime status, peer ID, listen addresses |
| GET /buddies | Buddy list with connection state |
| GET /folders | Folder list with sync status |
| GET /storage | Per-buddy storage path, file count and bytes |
| GET /sessions | Recent sync sessions with live counts, plus pending sync requests |
| GET /config | Current saved configuration |
| GET /logs | Recent log entries |
| GET /recovery | Export recovery metadata |
| POST /folders | Add folder |
| POST /folders/update | Edit a folder's name, path, append-only flag or buddy sharing |
| DELETE /folders/:name | Remove folder |
| POST /buddies/pair | Pair buddy through the local API |
| POST /buddies/pairing-code | Generate pairing code |
| DELETE /buddies/:id | Remove buddy |
| POST /sync | Ask the daemon to sync all folders now |
| POST /sync/:folder | Ask the daemon to sync one folder now |
| POST /config | Update selected config fields |
| POST /config/reload | Reload config from disk |
| POST /recovery/setup | Generate recovery phrase |
| POST /recovery/verify-word | Verify recovery word |
| POST /recovery/recover | Recover from mnemonic |
| POST /recovery/export | Export recovery metadata |
| POST /recovery/sync-config | Sync config to relay |
| POST /daemon/stop | Request daemon stop |

## Limitations

### Current

- Sync uses deterministic initiator selection (CGNAT-correct)
- Each connection carries one session and is dropped afterwards
- Buddy-backed config fetch for `recover` is not implemented yet (relay path works)
- No delta sync for large files (partial-chunk diffs)
- No selective download
- A queued sync request is served by the running daemon only
- Folder listings are one framed message (30 MB cap)

### Planned

- Better background daemon management
- Multiple buddies per folder
- Delta sync (rolling hash for partial-chunk diffs)
- Connection upgrade (replace relay with direct when possible)
- Long-lived CGNAT connections (keepalive)
- Buddy-backed config fetch for recovery

See [Features](/features) for user-facing capabilities or [Security](/security) for current security scope.
