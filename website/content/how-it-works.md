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

1. Each daemon publishes its address record to the relay API at `/discovery/<derived-key>`, where the key is derived from the pairing code (HMAC-authenticated)
2. The daemon looks up configured buddies using the same derived key (every 10 minutes)
3. It reads the peer ID, advertised multiaddrs, reachability flag, and sync time from the record
4. Deterministic initiator selection: the side without a public address initiates; if both same reachability, lower buddy UUID initiates
5. It dials a public TCP address directly, or falls back to a relay when configured
6. Cached addresses in `state.db` allow reconnection when the relay is temporarily unavailable

### NAT Traversal

Current connectivity options:

- **Public TCP address** - direct connection when `announce_addr` points to a reachable public address
- **UPnP** - automatic port forwarding attempt when no explicit `announce_addr` is set
- **Relay fallback** - used when `relay_region` is set and both sides store the same buddy `pairing_code`
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

Chunks are sent in 64KB blocks. LZ4 compression is used when it helps. When folder encryption is enabled, chunks are encrypted with random nonces (XSalsa20-Poly1305). Paths are encrypted with deterministic nonces so the same filename always encrypts the same way.

Restored files are hash-verified after write.

### Restore Behavior

Restore is just sync in the opposite direction:

1. One side advertises a file in its folder list
2. The other side sees the file is missing locally
3. The sync session requests the missing file
4. The file is recreated locally

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
| GET /status | Runtime status |
| GET /buddies | Buddy list with connection state |
| GET /folders | Folder list with sync status |
| GET /storage | What each buddy stores here |
| GET /sessions | Recent sync sessions and data transferred |
| GET /config | Current saved configuration |
| GET /logs | Recent log entries |
| GET /recovery | Export recovery metadata |
| POST /folders | Add folder |
| DELETE /folders/:name | Remove folder |
| POST /buddies/pair | Pair buddy through the local API |
| POST /buddies/pairing-code | Generate pairing code |
| DELETE /buddies/:id | Remove buddy |
| POST /sync/:folder | Sync with the folder's buddies now |
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
- Buddy-backed config fetch for `recover` is not implemented yet (relay path works)
- No delta sync for large files (partial-chunk diffs)
- No selective download

### Planned

- Better background daemon management
- Multiple buddies per folder
- Delta sync (rolling hash for partial-chunk diffs)
- Connection upgrade (replace relay with direct when possible)
- Long-lived CGNAT connections (keepalive)
- Buddy-backed config fetch for recovery

See [Features](/features) for user-facing capabilities or [Security](/security) for current security scope.
