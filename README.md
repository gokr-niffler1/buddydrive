# BuddyDrive

P2P folder sync and relay-backed restore for you and your buddies.

BuddyDrive lets you sync folders with 1-2 friends across the internet, bypassing NATs and firewalls. It also supports a 12-word recovery phrase, a per-installation master key, and relay-backed config restore so you can rebuild a lost machine and resync missing files.

## Documentation

| Document | Description |
|----------|-------------|
| [Tutorial](docs/TUTORIAL.md) | Hands-on guide: local smoke-test with two instances |
| [Manual](docs/MANUAL.md) | Complete reference: CLI, GUI, configuration, control API, security |
| [Development Plan](docs/PLAN.md) | Architecture decisions, implementation history, remaining work |

## Features

- **P2P Networking** - libp2p with relay-backed discovery, deterministic initiator selection, direct public TCP dialing, UPnP attempts, and relay fallback
- **Encrypted Backup** - files stored encrypted on your buddy's machine (filenames and content); deterministic path encryption for move detection, random content nonces for safety
- **Streaming Blake2b Hashing** - content-hashed sync with move and delete detection, no full-file-in-memory hashing
- **Recovery And Restore** - 12-word BIP39 recovery phrase (with checksum), Argon2i key derivation, encrypted config sync to relay, and config restore on a new machine
- **Restore Missing Files** - normal sync recreates files that exist on your buddy but are missing locally, with hash verification
- **Per-Buddy Sync Scheduling** - each buddy can have its own sync time; incoming connections always accepted
- **Folder Policies** - append-only mode prevents remote overwrites and remote deletions of existing local files; per-folder encryption flag
- **Simple CLI** - easy to use command-line interface
- **Web GUI** - browser-based UI served from the daemon, works on any device
- **GTK4 GUI** - native desktop application for monitoring and configuration (Linux)
- **Cross-Platform** - works on Linux, macOS, and Windows

## Quick Start

```bash
# Initialize your BuddyDrive identity
buddydrive init

# Optional but recommended: set up recovery
buddydrive setup-recovery

# Add a folder to sync
buddydrive add-folder ~/Documents --name docs

# Pair with a buddy
buddydrive add-buddy --generate-code
# Share the generated code with your buddy

# On your buddy's machine
buddydrive add-buddy --id <your-id> --code <pairing-code>

# Start the daemon
buddydrive start
```

See [docs/TUTORIAL.md](docs/TUTORIAL.md) for a detailed local testing guide.

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

- Per-buddy sync scheduling: set a sync window and interval for each buddy to control when to initiate connections:

```bash
buddydrive config set buddy-sync-window <buddy-id> 22:00-06:00
buddydrive config set buddy-sync-interval <buddy-id> 2h
```

The public TCP relay is at `relay-eu.buddydrive.org:41722`. The HTTP API (discovery, config sync, relay list) is at `https://api.buddydrive.org`. See the [buddydrive-relay repository](https://github.com/gokr/buddydrive-relay) for relay details and self-hosting notes.

## Roadmap

- [x] Delta sync (content-hash-based move/delete detection)
- [x] GTK4 desktop app
- [x] Web GUI (browser-based, served from daemon)
- [x] Bandwidth limiting
- [x] Encrypted backup (filenames + content encrypted on buddy's machine)
- [x] Per-buddy sync scheduling
- [x] Move and delete propagation
- [ ] System tray integration
- [ ] Auto-start on boot
- [ ] Debian package (deb)
- [ ] Package for other distros (rpm, brew)
- [ ] Multiple buddies per folder
- [ ] Selective sync (ignore patterns)
- [ ] Version history
- [ ] Buddy-backed config fetch for recovery

## Contributing

Contributions welcome. Please feel free to submit pull requests.

## License

MIT
