---
title: Getting Started
---

## Quick Start

### Prerequisites

- Linux, macOS, or Windows
- Internet connection
- A friend with BuddyDrive installed

### Install

**Linux:**

```bash
git clone https://github.com/gokr/buddydrive
cd buddydrive
nimble build
```

**macOS:**

```bash
git clone https://github.com/gokr/buddydrive
cd buddydrive
nimble build
```

**Windows:**

```powershell
git clone https://github.com/gokr/buddydrive
cd buddydrive
nimble build
```

### Initialize

```bash
buddydrive init
```

This creates:

- **Buddy ID** - a UUID that uniquely identifies your instance
- **Buddy Name** - a human-readable name
- Configuration file at `~/.buddydrive/config.toml`

### Pair With a Buddy

Exchange Buddy IDs first. Then, **on your machine:**

```bash
buddydrive add-buddy --generate-code --id <your-buddys-id>
```

This saves your buddy with a new pairing code and prints the command to send them. **On your buddy's machine:**

```bash
buddydrive add-buddy --id <your-id> --code ABCD-EFGH
```

Both sides must store the same code: it keys discovery and relay fallback for the two of you.

### Add a Folder

```bash
buddydrive add-folder ~/Documents --name docs
```

Options:

- `--name` - friendly name for the folder
- `--no-encrypt` - disable the folder's encryption flag in config
- `--append-only` - only accept new incoming files for that folder
- `--buddy <id>` - restrict the folder to a specific buddy

### Set Up Recovery

Enable recovery on the machine you want to protect:

```bash
buddydrive setup-recovery
```

BuddyDrive shows a 12-word recovery phrase, asks you to verify part of it, stores recovery metadata in `config.toml`, and syncs an encrypted config blob to the relay.

### Restore On a New Machine

On a replacement machine:

```bash
buddydrive recover
buddydrive start
```

Enter the same 12-word recovery phrase. If relay recovery succeeds, BuddyDrive restores your config locally. Starting the daemon then lets normal sync recreate missing files.

Current limitation: the CLI prompts for buddy fallback details if relay recovery fails, but that buddy-backed fetch path is not implemented yet.

### Start the Daemon

```bash
buddydrive start
```

Optional:

- `--port <control-port>` - change the local control API port
- `--daemon` - accepted, but currently continues in the foreground

### Per-Buddy Sync Time

Each buddy can have an optional sync time that controls when to initiate connections. Incoming connections are always accepted:

```bash
buddydrive config set buddy-sync-time <buddy-id> 03:00
```

When empty (default), the daemon initiates whenever it discovers a buddy address.

### Connectivity Notes

BuddyDrive connects peers using deterministic initiator selection: the side without a public address initiates (it dials the public side directly), or the side with the lower buddy UUID if both are the same reachability. Incoming connections from known buddies are always accepted. Connectivity options:

1. Direct connection with a public TCP address
2. Relay fallback using the stored pairing code

For direct connections, forward the configured `listen_port` on your router and set `[network].announce_addr` in `~/.buddydrive/config.toml` to a public multiaddr such as:

```toml
announce_addr = "/ip4/203.0.113.10/tcp/41721"
```

For relay fallback:

```bash
buddydrive config set api-base-url https://api.buddydrive.org
buddydrive config set relay-region eu
```

The public EU TCP relay is `relay-eu.buddydrive.org:41722`.

### Check Status

```bash
buddydrive status
```

### Current CLI Limitations

- `buddydrive start --daemon` is not fully implemented yet
- `buddydrive stop`, `Ctrl+C` or SIGTERM shut the daemon down cleanly
- `buddydrive status` shows configured state, not live daemon connectivity
- `buddydrive connect` does not perform a manual direct dial yet
- `buddydrive export-recovery` shows stored recovery metadata, not the original 12-word phrase
- `buddydrive init --with-recovery` is shown in help but returns an error if used; use `init` then `setup-recovery`

## GUI

### Launch

```bash
buddydrive-gui
```

### Features

- **Status panel** - daemon running, identity, uptime
- **Folders list** - configured folders and sync status
- **Buddies list** - paired buddies and their stored configuration
- **Add folder dialog** - select path, name, encryption flag, and append-only mode
- **Pair dialog** - generate or enter pairing details

## CLI Reference

### Commands

```text
buddydrive init                        Initialize BuddyDrive
buddydrive config                      Show configuration
buddydrive config set <key> ...        Update configuration values
  api-base-url <url>                  Set relay discovery URL
  relay-region <region>                 Set relay region (eu, us, local)
  storage-base-path <path>             Set incoming storage base path
  bandwidth-limit <kbps>               Set bandwidth limit (0 = unlimited)
  buddy-pairing-code <id> <code>       Set buddy pairing code
  buddy-name <name>                    Set buddy display name
  buddy-sync-time <id> <HH:MM>         Set buddy sync time (empty = always)
  folder-append-only <name> on|off     Toggle folder append-only mode
buddydrive add-folder <path>           Add folder to sync
  --name <name>                        Folder name
  --no-encrypt                         Disable folder encryption flag
  --append-only                        Only sync new files into that folder
  --buddy <id>                         Restrict folder to buddy
buddydrive remove-folder <name>        Remove folder
buddydrive list-folders                List configured folders
buddydrive add-buddy                   Pair with a buddy
  --id <buddy-id>                      Buddy ID to pair with
  --generate-code                      Generate a code, save it for this buddy
  --code <code>                        Pairing code your buddy generated
buddydrive remove-buddy <id>           Remove buddy
buddydrive list-buddies                List paired buddies
buddydrive connect <address>           Manual connect placeholder
buddydrive start                       Start sync daemon
  --port <control-port>                Override control API port
  --daemon                             Accepted but stays foreground
buddydrive stop                        Ask the daemon to shut down cleanly
buddydrive status                      Show configured status
buddydrive logs                        Show recent logs
buddydrive setup-recovery              Generate recovery phrase and sync encrypted config
buddydrive recover                     Restore config from recovery phrase
buddydrive sync-config                 Manually sync encrypted config to relay/buddies
buddydrive export-recovery             Show stored recovery metadata
buddydrive help                        Show help
```

### Examples

```bash
# Pair with a buddy (you generate, they enter the same code)
buddydrive add-buddy --generate-code --id <their-id>
buddydrive add-buddy --id <your-id> --code ABCD-EFGH   # on their machine

# Add folders
buddydrive add-folder ~/Photos --name photos
buddydrive add-folder ~/Documents --name docs --append-only

# Configure relay fallback
buddydrive config set api-base-url https://api.buddydrive.org
buddydrive config set relay-region eu
buddydrive config set buddy-pairing-code abc123 ABCD-EFGH

# Set up recovery
buddydrive setup-recovery

# Restore on a new machine
buddydrive recover

# Check what's configured
buddydrive list-folders
buddydrive list-buddies
buddydrive config
```

## Configuration

Config stored at `~/.buddydrive/config.toml`:

```toml
[buddy]
name = "Alice"
id = "fcd6295c-a912-44d4-a27b-ad898795207d"

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

[[folders]]
id = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
name = "docs"
path = "/home/alice/Documents"
encrypted = true
append_only = false
folder_key = "a1b2c3d4e5f6..."
buddies = ["bob-uuid"]

[[buddies]]
id = "bob-uuid"
name = "Bob"
pairing_code = "ABCD-EFGH"
sync_time = "03:00"
added_at = "2026-04-10T12:00:00Z"
```

## Files

| Location | Purpose |
|----------|---------|
| `~/.buddydrive/config.toml` | Configuration |
| `~/.buddydrive/state.db` | Runtime state |
| `~/.buddydrive/index.db` | File index |
| `~/.buddydrive/buddydrive.log` | Logs |
| `~/.buddydrive/port` | Control API port |

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
3. Remember `buddydrive status` does not show live connection state yet
4. Missing files are restored through normal sync after connectivity returns

## Next Steps

- Read [Features](/features) for capabilities
- Read [Security](/security) for current security scope
- Read [How It Works](/how-it-works) for architecture
