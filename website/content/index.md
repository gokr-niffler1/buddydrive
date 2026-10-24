---
title: BuddyDrive
tagline: Backup your life, with a friend
---

## Hero Section

**Title:** BuddyDrive
**Subtitle:** Backup your life, with a friend.
**Description:** Peer-to-peer encrypted folder sync with relay-backed restore. Keep your documents, photos, and other important folders encrypted on a trusted buddy machine, then rebuild a lost machine with a 12-word recovery phrase and resync missing files.

**CTA Primary:** Get Started
**CTA Secondary:** Learn More

## Why BuddyDrive?

Your NAS can burn. Your external drive can fail. Ransomware can encrypt everything. And cloud backups cost money every month, storing your data on servers you do not control.

**BuddyDrive is different.**

Pair with a friend, family member, or trusted colleague. Keep an offsite copy on their machine. Use a recovery phrase to get your config back when a machine dies. Let sync restore what is missing.

### Real Offsite Protection

- **Fire, flood, theft** - your backup is safe at your buddy's house
- **Restore after loss** - a 12-word recovery phrase rebuilds your config on a new machine
- **Zero monthly fees** - use hardware you already own
- **No accounts** - no cloud dashboard, no subscription, no vendor lock-in

## How It Works

1. **Install BuddyDrive** on both machines
2. **Pair devices** using a simple code
3. **Select folders** to sync and optionally enable recovery
4. **Restore when needed** - recover config with 12 words, then let sync recreate missing files

## The Problem With Cloud Backups

| Cloud Backup | BuddyDrive |
|-------------|------------|
| $5-20/month forever | Free, forever |
| Data stored on company servers | Data stored with your buddy |
| Trust the provider | Trust someone you know |
| Account required | No account required |
| Recover through vendor | Recover with your own 12 words |

## Features

### Direct Transport Encryption

Direct libp2p peer connections use Noise transport encryption. Folder contents are encrypted with XSalsa20-Poly1305 before being stored on your buddy's machine — they see only opaque encrypted blobs under hashed names, not your filenames or file data. Relay-backed config backups are encrypted with your recovery master key before upload.

### Recovery Phrase

Set up a 12-word recovery phrase once. BuddyDrive derives a master key from it, syncs an encrypted copy of your config to the relay, and lets you restore config on a replacement machine.

### Automatic Backup

Changed files are backed up in the background, in a session that runs when the two daemons connect. File moves are detected via content hashing (no re-upload for renames). If a file is missing locally but still exists on your buddy, the next successful session restores it with hash verification — and a file missing on one side is only treated as a delete when that side's index shows it held the path before.

Each buddy's folders are stored in a storage folder of their own, one directory per folder id, so two folders both named `docs` never collide. You own your folders: moves, deletes and restores are your decision, not your buddy's.

### Append-Only Protection

Mark a folder append-only when you want incoming sync to add missing files without overwriting the local copy that is already there.

### Open Source

100% open source. Audit the code. Contribute improvements. No hidden backdoors. No telemetry.

## Who Is This For?

- **Families** - offsite backup with people you already trust
- **Friends** - mutual backup without cloud costs
- **Small teams** - simple shared folder sync and restore
- **Privacy-conscious users** - local control over recovery secrets
- **Budget-conscious users** - free alternative to another subscription

## Get Started

BuddyDrive builds from source on Linux and macOS. Install it on two machines, pair them with one shared code, set up recovery, and start backing up.

[Download Now](/docs) or read the [full feature list](/features).
