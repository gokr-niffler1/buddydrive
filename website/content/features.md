---
title: Features
---

## Core Features

### Recovery And Restore

BuddyDrive now includes a recovery path for lost or rebuilt machines:

- **12-word recovery phrase** — standard BIP39 with SHA-256 checksum (catches transcription errors)
- **Master key** derived via Argon2i (stronger than BIP39's PBKDF2) then BLAKE2b
- **Encrypted config backup** synced to the relay
- **Config restore** via `buddydrive recover`
- **File restore through normal sync** after the recovered machine starts again

### Peer-to-Peer Architecture

No central sync account. No cloud drive. No vendor lock-in.

```text
Your Machine <--direct or relay--> Buddy's Machine
```

BuddyDrive uses a relay-backed API for peer discovery and libp2p for direct transport. Current connectivity options include direct public TCP connections and relay fallback. Features:

- **Relay API discovery** - find your buddy via pairing-code-derived keys on the relay
- **Deterministic initiator selection** - the side without a public address initiates; if both same reachability, lower buddy UUID initiates
- **Relay fallback** - available when both peers store the same pairing code for the relationship
- **Always accept incoming** - incoming connections from known buddies are accepted regardless of sync time
- **Yamux multiplexing** - multiple streams over one connection

### Automatic File Sync

Once paired and configured, BuddyDrive runs in the background:

- **File change detection** - notices new, modified, and deleted files
- **Move detection** - renamed files detected via content hash, no re-upload needed
- **Incremental sync** - only transfers what changed
- **Chunked transfer** - handles large files efficiently
- **Symlink support** - symlink targets are preserved across sync
- **Resume-friendly flow** - interrupted transfers can continue

### Encrypted Backup

When folder encryption is enabled (the default), filenames and file contents are encrypted before being stored on your buddy's machine:

- **Deterministic path encryption** — same filename always encrypts to the same ciphertext, enabling move detection without re-uploading
- **Random content nonces** — each 64KB chunk is encrypted with a fresh random nonce, preventing nonce reuse across file versions
- **Opaque storage** — your buddy sees only encrypted blobs, not your filenames or file contents
- **Unencrypted sharing mode** — set `encrypted = false` to share files plaintext for collaboration

### Restore Missing Files

The sync engine restores missing local files when they still exist on the buddy side:

- Lose a local copy
- Reconnect to your buddy
- BuddyDrive requests the missing file during the next sync
- The file is recreated locally and hash-verified

### Move and Delete Detection

BuddyDrive detects file renames and deletes efficiently:

- **Moved files** — detected via content hash matching; the buddy renames the encrypted path without re-uploading
- **Deleted files** — propagated to the buddy with a delete instruction
- **Content-hash-based comparison** — streaming blake2b hash used for change detection, not just mtime/size

### Folder Policies

Choose how each folder behaves:

- **Append-only mode** avoids remote overwrites of existing local files
- **Buddy-specific folders** restrict a folder to a selected buddy
- **Per-folder names** keep sync targets readable in the CLI and GUI

### Real-Time Status

GTK4 desktop application shows:

- Connection status for each buddy
- Sync progress per folder
- File counts and bytes transferred
- Recent activity log

The CLI provides the same core configuration and recovery flow for headless systems.

## Security Features

### Pairing Code

Pairing uses a short code that you share with your buddy out-of-band:

1. Generate a pairing code for your buddy; it is saved with them in your config
2. Share it with your buddy
3. They store the same code when adding you
4. That one shared code keys discovery and relay fallback for the two of you

### Direct Transport Encryption

Direct libp2p peer connections use Noise transport encryption. Recovery config blobs synced to the relay are encrypted with the recovery master key before upload. Folder contents are encrypted with XSalsa20-Poly1305 before being stored on the buddy's machine. Relay API mutations are authenticated with Ed25519 signatures derived from the master key.

### Recovery Metadata

Recovery stores:

- A `public_key` lookup value in `[recovery]`
- A locally stored `master_key`
- An encrypted config blob in the relay API

## Sync Features

### Conflict Handling

When both you and your buddy edit the same file:

- **Owner-authoritative by default** — the file owner's current version always replaces the storage copy
- **Append-only mode** avoids remote overwrites of existing local files
- **Missing files can still be restored** even in append-only mode
- **Move detection** avoids full re-upload when a file is renamed
- **No built-in version history yet**

### Large File Support

- Files split into 64KB chunks
- LZ4 compression when it reduces payload size
- Optional bandwidth limit through config

## Platform Support

### Linux

Build from source today. GTK4 GUI with desktop integration on Linux.

### macOS

Build from source.

### Windows

Build from source.

### Headless

Run on servers, NAS boxes, or Raspberry Pi with the CLI only.

## Technical Details

### Built With

- **Nim** - systems programming language
- **libp2p** - peer-to-peer networking
- **libsodium** - recovery config encryption helpers
- **GTK4** - desktop GUI
- **SQLite** - runtime status and file tracking

### Network Requirements

- Outbound internet access
- Direct mode needs a reachable public TCP address
- Relay mode needs a configured relay service and matching pairing code on both sides
- IPv4 and IPv6 supported

## Limitations

- Background sync depends on peers connecting successfully
- One buddy per folder today
- `recover` restores config from the relay path today; buddy-backed config fetch is not implemented yet
- `export-recovery` shows stored recovery metadata, not the original phrase
- `init --with-recovery` is shown in help but returns an error if used; use `init` then `setup-recovery`
- No mobile apps yet
- No file versioning yet

See [How It Works](/how-it-works) for architecture details.
