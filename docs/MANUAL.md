# BuddyDrive Manual

Complete reference for BuddyDrive CLI, GUI, configuration, and internals.

## Installation

### Prerequisites

- **Nim** 2.2.8 or later
- **libsodium** 1.0.18 or later
- **SQLite3** development headers
- **GTK4** development libraries (for native GUI, Linux only)
- **pkg-config** (for GUI build)
- **g++** (C++ compiler, required by libp2p's lsquic dependency)

### Linux (Debian/Ubuntu)

```bash
# Install Nim (using choosenim for version management)
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
source ~/.nimble/bin/nim

# Install system dependencies (CLI)
sudo apt update
sudo apt install -y build-essential g++ git libsodium-dev libsqlite3-dev liblz4-dev

# Install GTK4 dependencies (for native GUI)
sudo apt install -y pkg-config libgtk-4-dev

# Clone and build
git clone https://github.com/gokr/buddydrive.git
cd buddydrive
nimble build        # Build CLI
nimble gui_release  # Build GTK4 GUI
```

### macOS

```bash
# Install Homebrew if needed: https://brew.sh

# Install Nim via Homebrew
brew install nim

# Or use choosenim for version management
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
source ~/.nimble/bin/nim

# Install system dependencies
brew install libsodium sqlite3 gtk4 pkg-config

# Clone and build
git clone https://github.com/gokr/buddydrive.git
cd buddydrive
nimble build        # Build CLI
nimble gui_release  # Build GTK4 GUI
```

### Installing the GTK4 GUI

After building, install with desktop integration:

```bash
nimble install_gui
```

This installs:

- `buddydrive-gui` binary to `~/.local/bin/`
- Desktop entry to `~/.local/share/applications/`
- Icons to `~/.local/share/icons/`

After installation, BuddyDrive will appear in your applications menu.

### Debian/Ubuntu Package

```bash
# Install build dependencies
sudo apt install -y build-essential g++ git libsodium-dev libsqlite3-dev liblz4-dev debhelper dpkg-dev help2man

# Build the package
make deb

# The .deb file will be in the parent directory
sudo dpkg -i ../buddydrive_*.deb
```

### Using systemd

```bash
# Check if service is enabled/running
systemctl status buddydrive

# Enable to start on boot
sudo systemctl enable buddydrive

# Start/stop the service
sudo systemctl start buddydrive
sudo systemctl stop buddydrive

# View logs
journalctl -u buddydrive -f
```

## CLI Reference

### Commands

| Command | Description |
|---------|-------------|
| `buddydrive init` | Generate identity and create config |
| `buddydrive init --with-recovery` | Not yet implemented (use `init` then `setup-recovery`) |
| `buddydrive config` | Show current config |
| `buddydrive config set <key> ...` | Update runtime configuration |
| `buddydrive add-folder <path>` | Add folder to sync |
| `buddydrive remove-folder <name>` | Remove folder |
| `buddydrive list-folders` | List configured folders |
| `buddydrive add-buddy` | Add or pair with a buddy |
| `buddydrive remove-buddy <id>` | Remove buddy |
| `buddydrive list-buddies` | List paired buddies |
| `buddydrive connect <address>` | Manual connect placeholder |
| `buddydrive start [--port <control-port>]` | Start sync daemon in the foreground |
| `buddydrive stop` | Ask the running daemon to shut down cleanly |
| `buddydrive status` | Show configured folders, buddies, and sync time |
| `buddydrive logs` | Show recent logs |
| `buddydrive setup-recovery` | Generate and verify a 12-word recovery phrase, then sync encrypted config to the relay |
| `buddydrive recover` | Restore config from a 12-word recovery phrase and then resync folders |
| `buddydrive sync-config` | Manually push encrypted config to the relay and configured buddies |
| `buddydrive export-recovery` | Show stored recovery public key and master key metadata |
| `buddydrive takeover` | Make this machine the owner of your folders at your buddies, replacing another machine |

### config set Keys

| Key | Arguments | Description |
|-----|-----------|-------------|
| `api-base-url` | `<url>` | Set API base URL for discovery and config sync |
| `relay-region` | `<region>` | Set relay region (eu, us, local) |
| `storage-base-path` | `<path>` | Base folder for buddies without their own `buddy-storage-path` (default `~/.buddydrive/storage`) |
| `bandwidth-limit` | `<kbps>` | Set bandwidth limit (0 = unlimited) |
| `buddy-pairing-code` | `<buddy-id> <code>` | Set pairing code for a buddy |
| `buddy-name` | `<name>` | Update your buddy display name |
| `buddy-sync-window` | `<buddy-id> <HH:MM-HH:MM\|off>` | When this machine may start a sync with the buddy (off = any time). `buddy-sync-time` is an alias |
| `buddy-sync-interval` | `<buddy-id> <30m\|2h\|1h30m\|off>` | How often to sync with the buddy (off = every 5m until first contact, then 30m) |
| `buddy-addresses` | `<buddy-id> <multiaddr[,multiaddr]\|none>` | Known addresses for a buddy, dialed before discovered ones (e.g. a buddy on your LAN) |
| `buddy-storage-path` | `<buddy-id> <path\|default>` | Folder where this buddy's backups are kept on your machine |
| `folder-append-only` | `<folder-name> <on\|off>` | Toggle folder append-only mode |

### add-folder Options

| Flag | Description |
|------|-------------|
| `--name <name>` | Friendly name for the folder |
| `--no-encrypt` | Disable the folder's encryption flag in config |
| `--append-only` | Only accept new incoming files for that folder |
| `--buddy <id>` | Restrict the folder to a specific buddy |

### add-buddy Options

| Flag | Description |
|------|-------------|
| `--generate-code` | Generate a pairing code using the current local identity |
| `--id <buddy-id>` | Buddy ID to pair with |
| `--code <code>` | Pairing code from the buddy |

### start Options

| Flag | Description |
|------|-------------|
| `--port <control-port>` | Override control API port (default 17521) |
| `--daemon` | Accepted, but currently continues in the foreground |

### Current CLI Limitations

- `buddydrive init --with-recovery` is shown in help but not implemented; use `init` then `setup-recovery` separately
- `buddydrive start --daemon` currently prints a note and continues in the foreground
- `buddydrive stop`, `Ctrl+C` and SIGTERM (e.g. `systemctl stop`) all shut down cleanly: the daemon removes its discovery record and UPnP port mapping before exiting. A second `Ctrl+C` exits immediately
- `buddydrive status` does not yet query the running daemon for live connection state
- `buddydrive connect` does not perform a manual direct dial yet
- `buddydrive recover` currently restores configuration from the relay path; the buddy fallback prompt is present, but that fetch path is not implemented yet
- `buddydrive export-recovery` does not reveal the original 12-word phrase because the phrase is not stored locally

## Concepts

### Buddy Identity

When you run `buddydrive init`, your instance gets:

- **Buddy ID** — a UUID that uniquely identifies your BuddyDrive instance
- **Buddy Name** — a human-readable name (adjective-noun format like "purple-banana") displayed in outputs and shared during handshake

### Pairing

To sync folders with someone, you exchange Buddy IDs and then agree on **one** pairing code that both of you store:

1. Exchange Buddy IDs (shown by `buddydrive config` or the GUI)
2. One of you runs `buddydrive add-buddy --generate-code --id <their-id>`. This saves the buddy with a new code and prints the command to send them
3. The other runs that command: `buddydrive add-buddy --id <your-id> --code <pairing-code>`

In the GUIs, both of you use **Pair with Buddy**: one presses **Generate** and sends the code, the other enters it.

Both sides must store the same code. It is the shared secret for the relationship: discovery records are stored and looked up under a key derived from it, and relay fallback uses it to match the two peers. Keep it private: anyone with the code can read your buddy's published address. It does not prove who is on the other end; only buddy IDs you have added can connect.

### Recovery and Restore

BuddyDrive can store enough encrypted config in the relay to rebuild a machine later:

1. Run `buddydrive setup-recovery`
2. Write down the generated 12-word recovery phrase
3. BuddyDrive derives a master key, saves recovery metadata in `config.toml`, and syncs an encrypted config blob to the relay
4. On a replacement machine, run `buddydrive recover`, enter the same 12 words, then start the daemon to resync folders

Restore happens in two layers:

- **Config restore** — `buddydrive recover` fetches your encrypted config from the relay and writes `~/.buddydrive/config.toml`
- **File restore** — once the daemon is running again, normal sync recreates missing local files from your buddy

Append-only folders still protect existing local files from being overwritten or deleted by the remote side.

### One Machine Per Identity

Each buddy stores your folders for one machine at a time. Machines are told apart by a machine id kept in the data directory (`machine-id`), not in `config.toml`, so a recovered config does not carry it along. The first machine to back up a folder owns it there; another machine with the same identity is refused, and the log says so, rather than both overwriting each other's backup.

When a machine replaces another one, it takes over: `buddydrive recover` does this automatically, and `buddydrive takeover` does it for a config you copied by hand. On its next sync with each buddy the new machine claims your folders, restores what they hold, and from then on the old machine is refused. Only take over from a machine you have retired.

### Folder Policies

- **Encrypted** — folder encryption flag (default true). When enabled, filenames and content are encrypted before being stored on the buddy's machine. Path encryption uses deterministic nonces (same path always encrypts the same way, enabling move detection). Content encryption uses random nonces per chunk (prevents nonce reuse across versions).
- **Append-only** — prevents remote overwrites and remote deletions of existing local files. Missing files are still created. Because the folder never drops a file, a file deleted on the other side is restored back to it from the append-only copy on a later sync
- **Buddy-specific** — restrict a folder to sync with a specific buddy

### Per-Buddy Sync Window and Interval

Each buddy has an optional sync window and sync interval that control when this machine initiates a connection. Incoming connections from known buddies are always accepted regardless of either. Both can also be set with Edit on a buddy in the web GUI.

```bash
buddydrive config set buddy-sync-window <buddy-id> 22:00-06:00
buddydrive config set buddy-sync-interval <buddy-id> 2h
```

An empty window means any time; a window may cross midnight. A single time such as `03:00` (the older `sync_time` form) means the half hour around it. An empty interval means every 5 minutes until the buddy has been reached once, then every 30 minutes. The interval counts from the last attempt or session, whoever dialed.

## How It Works

### Peer Discovery

1. `buddydrive init` creates a local buddy identity and config file
2. `buddydrive start` creates the libp2p node for the running session
3. The daemon publishes your address to the relay at `/discovery/<derived-key>`, where the key is derived from the pairing code. The record includes peerId, addresses, `isPubliclyReachable`, sync time, and relay region
4. The daemon looks up configured buddies using the same derived key via the relay API (every 10 minutes)
5. Deterministic initiator selection: the side without a public address initiates; if both are the same reachability, the lower buddy UUID initiates
6. It connects directly when a public TCP address is available, or via relay fallback when configured
7. Cached addresses in `state.db` are used for graceful degradation when the relay is unavailable

### Recovery and Transport Security

- Direct libp2p connections use Noise transport encryption
- Recovery setup derives a 32-byte master key from the 12-word phrase
- Config sync encrypts the serialized config blob with the master key before uploading it to the relay API
- Normal sync restores missing files by comparing remote file lists with the local folder state

### Sync Protocol

1. Scans folder for changes (polling-based) using streaming blake2b hash
2. Detects added, modified, deleted, and moved files (move detection via content hash matching)
3. Exchanges file lists with buddy (includes encrypted paths and content hashes)
4. Computes deltas: missing files, modified files, moves, and deletes. A file the
   buddy has and you do not is only deleted when your index shows you held that
   path before; otherwise it is fetched. That is what makes restore onto an empty
   machine pull files down instead of wiping the buddy's copy
5. Transfers chunks (64KB, LZ4 compressed when beneficial, encrypted with random nonces)
6. Both sides update SQLite index
7. Restored files are hash-verified after write
8. File writes use atomic `.buddytmp` + `flushFile` + `moveFile` for crash safety
9. The session ends with a session-end exchange in a fixed order, so neither side
   hangs up while the other still has data in flight through a relay

### NAT Traversal

- **Public TCP address** — direct connection when `announce_addr` points to a reachable public address
- **UPnP** — automatic port forwarding attempt when no explicit `announce_addr` is set
- **Relay fallback** — used when `relay_region` is set and both sides store the same buddy `pairing_code`

### Connectivity

For direct connections, forward the configured `listen_port` on your router and set `[network].announce_addr` in `~/.buddydrive/config.toml` to a public multiaddr such as `/ip4/<public-ip>/tcp/41721`.

For relay fallback, configure relay region. The stored pairing code is reused as the relay shared secret:

```bash
buddydrive config set api-base-url https://api.buddydrive.org
buddydrive config set relay-region eu
```

## Configuration

Config file location: `~/.buddydrive/config.toml`

```toml
[buddy]
name = "purple-banana"
id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

[recovery]
enabled = true
public_key = "6J8h2qFvExampleRecoveryKey"
master_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

[network]
listen_port = 41721
announce_addr = "/ip4/203.0.113.10/tcp/41721"
api_base_url = "https://api.buddydrive.org"
relay_region = "eu"
storage_base_path = ""
bandwidth_limit_kbps = 0

[gui]
locale = "sv-SE"   # optional: date and number format in the web GUI; empty = the browser's language

[[folders]]
id = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
name = "docs"
path = "/home/user/Documents"
encrypted = true
append_only = false
folder_key = "a1b2c3d4e5f6..."
buddies = ["buddy-id-here"]

[[buddies]]
id = "buddy-id-here"
name = "cranky-wrench"
pairing_code = "ABCD-EFGH"
sync_window = "22:00-06:00"   # optional; older configs with sync_time are still read
sync_interval = "2h"          # optional
storage_path = "/mnt/backup/cranky-wrench"
addresses = ["/ip4/192.168.1.101/tcp/41721"]   # optional, see below
added_at = "2026-04-10T12:00:00Z"
```

### Buddies on the Same Network

Discovery records only carry public addresses (plus any `announce_addr`); private LAN addresses are never published. If a buddy is on your own network, for example while testing, give each side the other's LAN address:

```bash
buddydrive config set buddy-addresses <buddy-id> /ip4/192.168.1.101/tcp/41721
```

Those addresses are dialed first. The buddy still has to be found through discovery once, since that is where its peer ID comes from.

### Where a Buddy's Files Are Kept

Every buddy gets a storage folder of its own on your machine: `storage_path` if you set one, otherwise `<storage_base_path>/<buddy-id>` (by default `~/.buddydrive/storage/<buddy-id>`). Each folder the buddy shares with you lives in a sub-folder named by its folder id, so a buddy's `docs` never mixes with your own `docs`. Encrypted folders hold only opaque `.blob` files and small `.meta` sidecars; you cannot read their names or contents. Unencrypted folders are stored as normal files you can browse.

### Data Files

| Location | Purpose |
|----------|---------|
| `~/.buddydrive/config.toml` | Static configuration (identity, folders, buddies, recovery) |
| `~/.buddydrive/state.db` | Runtime state (SQLite): `runtime_status`, `buddy_state`, `folder_state`, `cached_buddy_addrs` |
| `~/.buddydrive/index.db` | File metadata index (SQLite) |
| `~/.buddydrive/port` | Control API port (written after daemon startup) |
| `~/.buddydrive/buddydrive.log` | Log file |

## Web GUI

The daemon serves a browser-based UI on the control port. It uses the same REST API as the CLI:

- **Localhost access**: `http://127.0.0.1:<port>/` — no authentication needed
- **LAN access**: `http://<ip>:<port>/w/<secret>/` — secret path derived from buddy UUID (first 8 chars, lowercase, no hyphens)
- Assets are embedded in the binary at compile time via `staticRead` — no external files needed
- The web GUI provides folder management, buddy pairing, settings, and log viewing

## Control API

REST API served by the daemon on `0.0.0.0:17521` by default. The actual port is written to `~/.buddydrive/port` after startup.

### Authentication

- **Localhost** (`127.0.0.1`, `::1`): No authentication required.
- **LAN**: Requests from non-localhost addresses must use a secret path prefix `/w/<secret>/`. Requests without the correct prefix receive `403 Forbidden`.

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/status` | Daemon status and identity |
| GET | `/buddies` | Buddy list with connection state |
| POST | `/buddies/pairing-code` | Generate pairing code |
| POST | `/buddies/pair` | Pair with a buddy (requires buddy ID and code) |
| DELETE | `/buddies/:id` | Remove a buddy |
| GET | `/folders` | Folder list with sync status |
| POST | `/folders` | Add folder |
| DELETE | `/folders/:name` | Remove folder |
| POST | `/sync/:folderName` | Trigger folder sync |
| GET | `/config` | Current saved configuration |
| POST | `/config` | Update selected config fields (returns `restartRequired` when needed) |
| POST | `/config/reload` | Reload configuration from disk |

### Recovery Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/recovery/setup` | Set up recovery with BIP39 mnemonic |
| POST | `/recovery/verify-word` | Verify a single word from the recovery phrase |
| POST | `/recovery/recover` | Restore config from 12-word mnemonic |
| GET | `/recovery` | Show current recovery status |
| POST | `/recovery/export` | Export recovery info |
| POST | `/recovery/sync-config` | Manually push encrypted config to the relay API |

### Error Responses

All errors follow this format:

```json
{
  "error": "Description",
  "code": "ERROR_CODE"
}
```

Common error codes: `FOLDER_NOT_FOUND`, `BUDDY_NOT_FOUND`, `INVALID_REQUEST`, `NOT_FOUND`, `INTERNAL_ERROR`, `NO_CONFIG`, `ALREADY_SETUP`, `NOT_SETUP`, `INVALID_MNEMONIC`, `MISMATCH`, `SYNC_FAILED`

### Notes

- `POST /config` returns `restartRequired` when the daemon needs a restart for changes to take effect
- The daemon also reloads config from disk automatically when `config.toml` changes (polls mtime in the discovery loop)

## Security

### Current Security Layers

| Component | Algorithm | Purpose |
|-----------|-----------|---------|
| Direct peer transport | libp2p Noise | Encrypt direct libp2p connections |
| Folder content encryption | libsodium `crypto_secretbox` (XSalsa20-Poly1305) | Encrypt filenames and file contents stored on buddy's machine |
| Path encryption | Deterministic nonce from folderKey + path | Same path always encrypts to same ciphertext (enables move detection) |
| Chunk encryption | Random nonce per 64KB chunk | Prevents nonce reuse across file versions |
| Recovery config backup | libsodium `crypto_secretbox` | Encrypt config synced to relay |
| Pairing code | Shared secret | Match buddies, derive discovery keys, HMAC-authenticate relay records, relay fallback |
| Recovery mnemonic | Standard BIP39 (128-bit entropy + SHA-256 checksum) | Re-derive recovery metadata on a new machine; checksum catches transcription errors |
| Mnemonic-to-seed | Argon2i (`crypto_pwhash`, moderate tier) | Key derivation from mnemonic (stronger than BIP39's PBKDF2) |
| Seed-to-master key | BLAKE2b-256 | Deterministic master key from 64-byte seed |
| Public key (lookup) | BLAKE2b-256 of master key + Base58 | Relay API lookup key (not an asymmetric public key) |
| Relay API signing | Ed25519 (derived from master key) | Authenticate relay API mutations (PUT/DELETE) |
| Content hashing | BLAKE2b-256 (streaming) | File change detection, move detection, restore verification |
| Folder key derivation | BLAKE2b-256 (masterKey + folder ID) | Per-folder encryption key, stable across renames |
| Password hashing | Argon2i (`crypto_pwhash_str`) | Password storage with auto-upgrading parameters |

### Threat Model

**Protected against:**

- Network interception on direct libp2p connections (Noise transport)
- Buddy reading your files (encrypted filenames and content when folder encryption is enabled)
- Relay compromise for config backup (encrypted with recovery master key)
- Lost machine (recovery rebuilds config, sync restores files)
- File corruption (restored files are hash-verified after write)

**Not protected against:**

- Untrusted buddies when folder encryption is disabled (`encrypted = false` shares files plaintext)
- Machine compromise (malware can read files before or during sync)
- Denial of service (attacker can prevent peer connections)

### Encryption Details

When `encrypted = true` on a folder:
- **Filenames** are encrypted with deterministic nonces derived from `folderKey + "/path/" + plaintextPath`, then base64-encoded. Same path always produces the same encrypted path, enabling move detection.
- **File content** is split into 64KB chunks, each encrypted with a random 24-byte nonce prepended to the ciphertext. Random nonces prevent nonce reuse when the same file is modified across versions.
- **Folder key** is derived from `crypto_generichash(masterKey + "/folder/" + folderId)` when recovery is enabled, or a random key stored in `folder_key` in config.toml otherwise.
- Your buddy stores fully opaque encrypted blobs — they cannot read filenames or content.
- The content hash your buddy keeps is keyed with the folder key, so it cannot be matched against files they know. They do see each file's size, mtime and permission bits.

When `encrypted = false`:
- Files are stored plaintext on the buddy's machine for collaboration.
- Content hashes (blake2b-256) are still used for change detection and move detection.

### Recovery Key Derivation

The full derivation chain from the 12-word mnemonic to all derived keys:

```
12-word mnemonic (standard BIP39: 128-bit entropy + SHA-256 checksum)
  │
  ▼  Argon2i (crypto_pwhash, moderate tier, 256 MB memory)
  │  salt = "mnemonic" (padded to 16 bytes)
  │  output = 64 bytes
  ▼
seed (64 bytes)
  │
  ▼  BLAKE2b-256 (crypto_generichash)
  ▼
master key (32 bytes, hex in config.toml [recovery].master_key)
  │
  ├──► BLAKE2b-256 + Base58 → publicKeyB58 (relay lookup key, not an asymmetric public key)
  │
  ├──► Ed25519 (crypto_sign_seed_keypair) → signing keypair for relay API authentication
  │    Headers: X-BD-Verify-Key, X-BD-Version, X-BD-Timestamp, X-BD-Signature
  │
  └──► BLAKE2b-256 (masterKey + "/folder/" + folderId) → folder key (per-folder encryption key)
```

BuddyDrive follows the standard BIP39 specification for mnemonic generation and validation (128-bit entropy + SHA-256 checksum), tested against official BIP39 test vectors. The key derivation step diverges from BIP39 by using Argon2i instead of PBKDF2-HMAC-SHA512 — this provides stronger resistance to GPU and ASIC attacks. The consequence is that other BIP39-compatible tools cannot derive the same master key from a BuddyDrive mnemonic.

## Relay Server

The relay enables NAT traversal and encrypted config storage. See the [buddydrive-relay repository](https://github.com/gokr/buddydrive-relay) for full details.

### Public Relay

- **TCP relay**: `relay-eu.buddydrive.org:41722` (for NAT traversal)
- **API**: `https://api.buddydrive.org` (for discovery, encrypted config storage, and relay lists)
- **Region**: Frankfurt (fra)

### Self-Hosted Relay

See the [buddydrive-relay repository](https://github.com/gokr/buddydrive-relay) for build instructions, configuration, Docker, and Koyeb deployment options.

## Troubleshooting

### Daemon won't start

```bash
buddydrive logs
buddydrive config
```

### Can't connect to buddy

1. Both peers need internet access
2. Both peers need `buddydrive start` running
3. Check stored buddies with `buddydrive list-buddies`
4. For direct mode, verify port forwarding and `announce_addr`
5. For relay mode, verify `relay-region`, `api-base-url`, and matching pairing codes

### Files not syncing

1. Check daemon logs with `buddydrive logs`
2. Check folder configuration with `buddydrive list-folders`
3. `buddydrive status` does not show live connection state yet
4. Missing files are restored through normal sync after connectivity returns

### Address already in use

Set different `listen_port` values in each instance's config, and use different `--port` values when starting the daemons.

### `buddydrive status` shows buddies as offline

Expected. The CLI status command reads configured state, but does not yet report live daemon connectivity.

## Roadmap

- [x] Encrypted backup (filenames + content encrypted on buddy's machine)
- [x] Move and delete propagation
- [x] Content-hash-based sync (streaming blake2b)
- [x] Per-buddy sync scheduling
- [x] Deterministic initiator selection (CGNAT-correct)
- [ ] Delta sync (rolling hash for partial-chunk diffs)
- [x] GTK4 desktop app
- [x] Web GUI (browser-based, served from daemon)
- [x] Bandwidth limiting
- [ ] System tray integration
- [ ] Auto-start on boot
- [ ] Debian package (deb)
- [ ] Package for other distros (rpm, brew)
- [ ] Multiple buddies per folder
- [ ] Selective sync (ignore patterns)
- [ ] Version history
- [ ] Buddy-backed config fetch for recovery
