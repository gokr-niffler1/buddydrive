# BuddyDrive

P2P encrypted folder backup and relay-backed restore for you and your buddies.

BuddyDrive backs up folders to 1-2 friends across the internet, bypassing NATs and firewalls. Each buddy keeps your folders encrypted in storage of their own, so they are storage, not a co-author: they cannot read your filenames or your data. It also supports a 12-word recovery phrase, a per-installation master key, and relay-backed config restore, so you can rebuild a lost machine and resync missing files.

## Documentation

| Document | Description |
|----------|-------------|
| [Tutorial](docs/TUTORIAL.md) | Hands-on guide: a real two-instance sync on one machine |
| [Manual](docs/MANUAL.md) | Complete reference: CLI, GUI, configuration, control API, security |
| [Architecture](docs/architecture.md) | Connection, discovery and session flow diagrams |
| [Development Plan](docs/PLAN.md) | Architecture decisions, implementation history, remaining work |

## Features

- **P2P Networking** - libp2p with relay-API discovery, deterministic initiator selection, direct public TCP dialing, UPnP attempts, and relay fallback
- **Encrypted Backup, Not Mirroring** - each buddy's folders go to a storage folder of their own, one directory per folder id, so a buddy's `docs` never collides with yours. Encrypted folders are stored as opaque `.blob` files plus `.meta` sidecars; blob names are hashes, so nothing on disk reveals your file names
- **Owner Is Authoritative** - the side that owns a folder alone decides moves, deletes and restores; the storage side keeps what it is told and never deletes on its own
- **Streaming BLAKE2b Hashing** - content-hashed sync with move and delete detection, no full-file-in-memory hashing
- **Recovery And Restore** - 12-word BIP39 recovery phrase (with checksum), Argon2i key derivation, encrypted config sync to the relay, and config restore on a new machine
- **Restore Missing Files** - normal sync recreates files that exist on your buddy but are missing locally, with hash verification
- **Per-Buddy Sync Scheduling** - each buddy can have its own sync time; incoming connections always accepted
- **Folder Policies** - append-only mode prevents remote overwrites and remote deletions of existing local files; per-folder encryption flag; per-folder buddy sharing
- **Crash-Safe Receiving** - files are written to `.buddytmp`, flushed, then renamed into place; leftovers are cleaned up on the next start
- **Clean Shutdown** - `buddydrive stop`, `Ctrl+C` and `SIGTERM` unpublish the discovery record and remove the UPnP mapping before exiting
- **Simple CLI** - easy to use command-line interface
- **Web GUI** - browser-based UI served from the daemon, works on any device
- **GTK4 GUI** - native desktop application for monitoring and configuration (Linux)
- **Linux And macOS** - build from source on both; the GTK4 GUI is Linux only

BuddyDrive is not a sync-everywhere drive: it is a mutual encrypted backup between two people who trust each other's storage. Buddy A's copy on Buddy B's disk is a backup, not a shared working tree.

## Quick Start

```bash
# Initialize your BuddyDrive identity
buddydrive init

# Optional but recommended: set up recovery
buddydrive setup-recovery

# Add a folder to back up
buddydrive add-folder ~/Documents --name docs

# Exchange Buddy IDs (shown by `buddydrive config`)
# Then, on your machine: generate one pairing code for this buddy
buddydrive add-buddy --generate-code --id <their-id>

# On your buddy's machine, run the command it printed
buddydrive add-buddy --id <your-id> --code <pairing-code>

# Start the daemon on both sides
buddydrive start
```

Both sides must store the **same** pairing code. It is the shared secret for the
relationship: discovery records are stored under a key derived from it, and
relay fallback matches the two peers with it.

See [docs/TUTORIAL.md](docs/TUTORIAL.md) for a detailed local testing guide.

## Installation

### Prerequisites

- **Nim** 2.2.8 or later
- **libsodium** 1.0.18 or later
- **SQLite3** development headers
- **liblz4** development headers
- **GTK4** development libraries (for native GUI, Linux only)
- **pkg-config** (for GUI build)
- **g++** and **GCC/clang** (required by libp2p's lsquic and boringssl dependencies)

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
brew install libsodium sqlite3 lz4 gtk4 pkg-config

# Clone and build
git clone https://github.com/gokr/buddydrive.git
cd buddydrive
nimble build        # Build CLI
nimble gui_release  # Build GTK4 GUI
```

`config.nims` links libsodium from `/usr/local/lib` and `/opt/homebrew/lib` on
macOS, which covers both Intel and Apple Silicon Homebrew prefixes.

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

### Using the Web GUI

The web GUI is built into the CLI — no separate build needed. When the daemon starts, it serves the web UI on the control port (default `17521`):

- **Localhost**: `http://127.0.0.1:17521/`
- **LAN**: `http://<your-ip>:17521/w/<secret>/` (the secret is derived from your buddy UUID and printed at startup)

The web GUI works on any device with a browser — phone, tablet, or headless server.

## Concepts

### Buddy Identity

When you run `buddydrive init`, your instance gets:

- **Buddy ID** - a UUID that uniquely identifies your BuddyDrive instance
- **Buddy Name** - a human-readable name displayed in outputs and shared during handshake

### Pairing

To sync folders with someone, you exchange Buddy IDs and then agree on **one** pairing code that both of you store:

1. Exchange Buddy IDs (shown by `buddydrive config` or the GUI)
2. One of you runs `buddydrive add-buddy --generate-code --id <their-id>`. This saves the buddy with a new code and prints the command to send them
3. The other runs that command: `buddydrive add-buddy --id <your-id> --code <pairing-code>`

In the GUIs, both of you use **Pair with Buddy**: one presses **Generate** and sends the code, the other enters it.

Both sides must store the same code. It is the shared secret for the relationship: discovery records are stored and looked up under a key derived from it, and relay fallback uses it to match the two peers. Keep it private: anyone with the code can read your buddy's published address. It does not prove who is on the other end; only buddy IDs you have added can connect.

### Recovery And Restore

BuddyDrive can store enough encrypted config in the relay to rebuild a machine later:

1. Run `buddydrive setup-recovery`
2. Write down the generated 12-word recovery phrase
3. BuddyDrive derives a master key, saves recovery metadata in `config.toml`, and syncs an encrypted config blob to the relay
4. On a replacement machine, run `buddydrive recover`, enter the same 12 words, then start the daemon to resync folders

Restore happens in two layers:

- **Config restore** - `buddydrive recover` fetches your encrypted config from the relay and writes `~/.buddydrive/config.toml`
- **File restore** - once the daemon is running again, normal sync recreates missing local files from your buddy

A buddy stores your folders for **one machine at a time**. Machines are told
apart by a machine id kept in the data directory, not in `config.toml`, so a
recovered config does not drag the old identity along. The first machine to back
a folder up owns it there; another machine with the same identity is refused
rather than silently overwriting the backup. `buddydrive recover` hands
ownership to the new machine automatically — and if you moved `config.toml` by
hand instead, run `buddydrive takeover` once before starting the daemon.

Append-only folders still protect existing local files from being overwritten or deleted by the remote side.

### Connectivity Notes

- BuddyDrive uses deterministic initiator selection: the side without a public address initiates (it dials the public side directly); if both are public or both private, the side with the lower buddy UUID initiates.
- Incoming connections from known buddies are always accepted regardless of sync time.
- For direct connections, forward the configured `listen_port` on your router and set `[network].announce_addr` in `~/.buddydrive/config.toml` to a public multiaddr such as `/ip4/<public-ip>/tcp/41721`.
- For relay fallback, configure relay region. The stored pairing code is reused as the relay shared secret:

```bash
buddydrive config set api-base-url https://api.buddydrive.org
buddydrive config set relay-region eu
```

- Per-buddy sync scheduling: a window says when this machine may *start* a sync
  with that buddy, and an interval says how often it tries. Incoming
  connections from a known buddy are always accepted, whatever the window says.

```bash
buddydrive config set buddy-sync-window <buddy-id> 22:00-06:00
buddydrive config set buddy-sync-interval <buddy-id> 2h
```

  Defaults: every 5 minutes until the two have made contact, then every 30
  minutes; no window means any time. You can also ask for a sync right now
  (`POST /sync` on the control API, or the Sync button in either GUI).

### Buddies on the Same Network

Discovery records only carry public addresses (plus any `announce_addr`); private
LAN addresses are never published. If a buddy is on your own network, give each
side the other's LAN address:

```bash
buddydrive config set buddy-addresses <buddy-id> /ip4/192.168.1.101/tcp/41721
```

Those addresses are dialed first, and they are enough for a sync without a
public IP or a relay on either side.

The public TCP relay is at `relay-eu.buddydrive.org:41722`. The HTTP API (discovery, config sync, relay list) is at `https://api.buddydrive.org`. See the [buddydrive-relay repository](https://github.com/gokr/buddydrive-relay) for relay details and self-hosting notes.

## Development

```bash
nimble build          # CLI (debug)
nimble build -d:release
nimble gui_release    # GTK4 GUI
nimble test           # full suite: 17 unit + 7 integration test files
nimble testUnit       # unit tests only
nimble testIntegration
make deb              # Debian package (needs debhelper, dpkg-dev, help2man)
```

There is no separate lint step; the Nim compiler type-checks during build. The
test suite runs under [testament](https://github.com/nim-lang/testament).
Integration tests start their own in-process relay and KV stubs and **fail**
rather than skip, so a green run means the sync path really ran.

See [AGENTS.md](AGENTS.md) for the source layout, sync model invariants and
language notes, and [docs/PLAN.md](docs/PLAN.md) for the design history.

## Roadmap

- [x] Content-hash-based move/delete detection
- [x] GTK4 desktop app
- [x] Web GUI (browser-based, served from daemon)
- [x] Bandwidth limiting
- [x] Encrypted backup (filenames + content encrypted on buddy's machine)
- [x] Per-buddy storage folders and per-folder buddy sharing
- [x] Per-buddy sync scheduling
- [x] Move and delete propagation
- [x] Clean daemon shutdown (`stop`, `Ctrl+C`, `SIGTERM`)
- [x] Debian package (`make deb`)
- [ ] System tray integration
- [ ] Auto-start on boot (the Debian package ships a systemd unit)
- [ ] Package for other distros (rpm, brew)
- [ ] More than one buddy per folder with conflict handling
- [ ] Selective sync (ignore patterns)
- [ ] Version history
- [ ] Buddy-backed config fetch for recovery (relay path only today)

## Contributing

Contributions welcome. Please feel free to submit pull requests.

## License

MIT
