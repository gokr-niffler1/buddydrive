---
title: Security
---

## Your Security Matters

BuddyDrive is designed around a simple principle: you should understand exactly what is protected today, and what still depends on trusting your buddy.

## What Exists Today

BuddyDrive currently has these security layers:

| Component | Algorithm | Purpose |
|-----------|-----------|---------|
| Direct peer transport | libp2p Noise | Encrypt direct libp2p connections |
| Folder content encryption | libsodium `crypto_secretbox` (XSalsa20-Poly1305) | Encrypt filenames and file contents stored on buddy's machine |
| Path encryption | Deterministic nonce from folderKey + path | Same path always encrypts to same ciphertext (enables move detection) |
| Chunk encryption | Random nonce per 64KB chunk | Prevents nonce reuse across file versions |
| Recovery config backup | libsodium `crypto_secretbox` | Encrypt config synced to relay |
| Pairing code | Shared secret | Match buddies, derive discovery keys, HMAC-authenticate relay records, and relay fallback sessions |
| Recovery mnemonic | Standard BIP39 (128-bit entropy + SHA-256 checksum) | Re-derive recovery metadata on a new machine; checksum catches transcription errors |
| Mnemonic-to-seed | Argon2i (moderate tier, 256 MB memory) | Key derivation from mnemonic (stronger than BIP39's PBKDF2) |
| Master key | BLAKE2b-256 of seed | Deterministic 32-byte key from 64-byte Argon2i output |
| Public key (lookup) | BLAKE2b-256 of master key + Base58 | Relay API lookup key (not an asymmetric public key) |
| Relay API signing | Ed25519 (derived from master key) | Authenticate relay API mutations |
| Content hashing | BLAKE2b-256 (streaming, 64KB chunks) | File change detection, move detection, restore verification |

## Recovery Phrase And Master Key

When you run `buddydrive setup-recovery`:

1. BuddyDrive generates 128 bits of random entropy
2. A SHA-256 checksum (4 bits) is appended, and the 132 bits are encoded as a 12-word mnemonic using the BIP39 English wordlist — this follows the standard BIP39 specification
3. The mnemonic is fed through Argon2i (moderate tier, 256 MB memory) to produce a 64-byte seed
4. The seed is hashed with BLAKE2b to produce the 32-byte master key
5. Recovery metadata is stored in `config.toml`
6. The serialized config is encrypted with the master key before syncing it to the relay

When you later run `buddydrive recover`, BuddyDrive uses the same 12 words to derive the same recovery material, fetches the encrypted config from the relay, decrypts it locally, and writes the restored config.

The checksum in the mnemonic catches most single-word transcription errors — if you write down one word incorrectly, validation fails rather than silently producing the wrong key.

**Key derivation divergence**: BuddyDrive uses Argon2i for mnemonic-to-seed instead of BIP39's standard PBKDF2-HMAC-SHA512. Argon2i is more resistant to GPU and ASIC attacks. The consequence is that other BIP39 tools cannot derive the same master key from a BuddyDrive mnemonic.

## Control API Access

The control API binds to all interfaces (default port 17521):

- **Localhost** (`127.0.0.1`, `::1`): No authentication required
- **LAN**: Requests must use a secret path prefix `/w/<secret>/` derived from your buddy UUID (first 8 hex characters). Requests without the correct secret receive 403 Forbidden

The secret provides basic protection but is low-entropy (32 bits). Only access the web GUI on trusted networks or over localhost.

## Pairing And Direct Connections

The pairing code is a shared secret between buddies:

- You share it out-of-band with someone you trust
- Both sides store it for that buddy relationship
- Relay fallback uses it to match the two peers
- Direct libp2p connections use Noise transport encryption once connected

## Current Scope And Limits

- Direct libp2p transport is encrypted by Noise
- Folder contents (filenames and file data) are encrypted with XSalsa20-Poly1305 before being stored on the buddy's machine when `encrypted = true` (the default)
- Recovery config blobs synced to the relay are encrypted with the recovery master key
- Restore works by recovering config first and then letting normal sync recreate missing files
- Restored files are hash-verified after write
- Append-only protects existing local files from remote overwrite

When `encrypted = false` (sharing mode), files are stored plaintext on the buddy's machine. Pair only with buddies you trust for unencrypted folders.

## What Your Buddy Can See Today

When folder encryption is enabled (default):

Your buddy **cannot** see:
- Your original filenames (encrypted with deterministic path encryption)
- Your file contents (encrypted with random nonces per chunk)
- Whether you have a particular file: the content hashes it keeps are keyed with the folder key, so they cannot be matched against files your buddy already knows
- The encrypted recovery config stored in the relay without your recovery phrase
- Your other buddies' configuration unless you share it with them

Your buddy **can** see:
- How many files you back up, and each file's size, modification time and permission bits
- When a file's content changes (its keyed hash changes)
- The total storage use and sync timing

When folder encryption is disabled (`encrypted = false`):
- Your buddy can see folder and file names, and read file contents

## Threat Model

### What We Protect Against

**Network interception on direct libp2p connections**: Noise protects direct peer transport.

**Relay compromise for config backup**: the relay stores an encrypted config blob; without the recovery phrase-derived master key it should not be readable.

**Lost machine**: recovery lets you rebuild config on a replacement device and then resync missing files.

### What We Do Not Protect Against

**Untrusted buddies with unencrypted folders**: if you pair with someone you do not trust and use `encrypted = false`, they can read your synced files.

**Your machine compromised**: malware on your machine can read files before or during sync.

**Denial of service**: an attacker can still prevent peers from connecting.

## Secure Pairing Guidelines

Only pair with people you trust:

1. Share codes verbally or in person when possible
2. Verify identity through a second channel
3. Use unique codes for each buddy relationship
4. Check buddy IDs on both machines

## Security Checklist

- [ ] Pair only with trusted buddies
- [ ] Verify buddy ID after pairing
- [ ] Write down the 12-word recovery phrase and store it offline
- [ ] Keep your system updated
- [ ] Use strong local passwords
- [ ] Consider full-disk encryption on your machine
- [ ] Regularly check sync activity

## Bottom Line

BuddyDrive protects direct libp2p transport with Noise, encrypts relay-backed recovery config with your master key, and encrypts folder filenames and contents with XSalsa20-Poly1305 before storing them on your buddy's machine. Your buddy sees only opaque encrypted blobs. Set `encrypted = false` only for active collaboration with buddies you trust.
