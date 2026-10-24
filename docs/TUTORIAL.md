# BuddyDrive Tutorial

A hands-on guide to getting BuddyDrive running and testing it locally. For full command reference and configuration details, see [MANUAL.md](MANUAL.md).

This tutorial runs **two isolated instances on one machine** and ends with a real
sync: each side backs up its folder onto the other, encrypted.

## Key Concepts

- **Buddy ID** - a UUID that identifies a BuddyDrive instance
- **Buddy Name** - a human-readable name shared during handshake
- **Pairing Code** - the shared secret for the relationship: it keys discovery records, matches the two peers for relay fallback, and is used for the relay rendezvous
- **Storage folder** - where a buddy's backed-up folders live on *your* disk, one directory per folder id

## How a Sync Actually Looks

BuddyDrive is a mutual encrypted backup, not a mirror. When Buddy 1 backs up its
`docs` folder to Buddy 2:

- Buddy 2 stores it under `~/.buddydrive/storage/<buddy-1-id>/<folder-id>/`
- an encrypted folder is stored as opaque `.blob` files plus `.meta` sidecars; blob names are hashes, so Buddy 2 cannot read the file names
- Buddy 1 is the only authority on that folder. Moves, deletes and restores are decided by Buddy 1; Buddy 2 keeps what it is told and never deletes on its own

Because of that, Buddy 2's own `docs` folder and Buddy 1's `docs` backup never
collide, even though they have the same name.

## Prerequisites

```bash
cd buddydrive   # wherever you cloned the repo
nimble build
```

Two instances on one machine need two things: different listen ports, and each
side told the other's address (discovery never publishes private addresses).

## Step 1: Create Two Isolated Homes

```bash
mkdir -p /tmp/buddy1/Documents
mkdir -p /tmp/buddy2/Documents

printf 'Hello from Buddy 1!\n' > /tmp/buddy1/Documents/from-buddy1.txt
printf 'Hello from Buddy 2!\n' > /tmp/buddy2/Documents/from-buddy2.txt
```

## Step 2: Initialize Both Instances

`HOME` isolates each instance, so config, storage and indexes stay apart:

```bash
HOME=/tmp/buddy1 ./bin/buddydrive init
HOME=/tmp/buddy2 ./bin/buddydrive init
```

Each instance gets its own config under `/tmp/buddyX/.buddydrive/config.toml`.

## Step 3: Give the Second Instance a Different Listen Port

Both default to `listen_port = 41721`, so the second one must change before you
start them together:

```bash
sed -i 's/^listen_port = 41721/listen_port = 41722/' /tmp/buddy2/.buddydrive/config.toml
```

## Step 4: Add a Folder to Each Instance

```bash
HOME=/tmp/buddy1 ./bin/buddydrive add-folder /tmp/buddy1/Documents --name docs
HOME=/tmp/buddy2 ./bin/buddydrive add-folder /tmp/buddy2/Documents --name docs
```

## Step 5: Collect Both Buddy IDs

```bash
HOME=/tmp/buddy1 ./bin/buddydrive config
HOME=/tmp/buddy2 ./bin/buddydrive config
```

Copy the `ID:` value from each command.

## Step 6: Pair Both Sides With One Shared Code

One side generates the code, the other enters it. Both end up with the same
code, which is what lets them find each other:

```bash
# On Buddy 1: generate a code for Buddy 2
HOME=/tmp/buddy1 ./bin/buddydrive add-buddy --generate-code --id <BUDDY2_UUID>
```

That prints the command to hand to your buddy. Run it on Buddy 2:

```bash
HOME=/tmp/buddy2 ./bin/buddydrive add-buddy --id <BUDDY1_UUID> --code <CODE>
```

Do **not** generate a code on both sides: the buddies would hold two different
codes and could never meet.

## Step 7: Tell Each Side the Other's Address

Discovery records only carry public addresses, so for two instances on one LAN
(the normal case when testing) give each side the other's address explicitly.
Those addresses are dialed first.

```bash
HOME=/tmp/buddy1 ./bin/buddydrive config set buddy-addresses <BUDDY2_UUID> /ip4/127.0.0.1/tcp/41722
HOME=/tmp/buddy2 ./bin/buddydrive config set buddy-addresses <BUDDY1_UUID> /ip4/127.0.0.1/tcp/41721
```

Use your LAN IP instead of `127.0.0.1` if the two instances are on different
machines on the same network.

## Step 8: Verify the Saved Configuration

```bash
HOME=/tmp/buddy1 ./bin/buddydrive list-folders
HOME=/tmp/buddy1 ./bin/buddydrive list-buddies
```

You should see one folder and one buddy per side, and the buddy entry should
show the same pairing code on both.

## Step 9: Start Both Daemons

Use a different control API port for each process so both can run at once.

**Terminal 1 (Buddy 1):**

```bash
HOME=/tmp/buddy1 ./bin/buddydrive start --port 17521
```

**Terminal 2 (Buddy 2):**

```bash
HOME=/tmp/buddy2 ./bin/buddydrive start --port 17522
```

Expected startup output includes lines like:

```text
Starting daemon...
Attempting UPnP port mapping for port 41721...
UPnP not available (no router support or already forwarded)
Node started with Peer ID: 16Uiu2HAm...
Direct-only mode: no public TCP address is being advertised. Forward TCP port 41721 ...
Checking 1 buddies...
Daemon started successfully

BuddyDrive is running!
Control API: http://127.0.0.1:17521
Listening addresses:
  /ip4/127.0.0.1/tcp/41721
  /ip4/192.168.1.101/tcp/41721
Control server started on port 17521
Web GUI (localhost): http://127.0.0.1:17521/
Web GUI (LAN): http://<your-ip>:17521/w/<secret>/
```

The `Direct-only mode` warning is expected when you have no public address. With
`buddy-addresses` configured it does not stop a sync.

The second daemon that starts should connect, and both sides should print:

```text
Connected to peer: 16Uiu2HAm...
Handshake successful with: purple-banana
Folder sync finished with: purple-banana
```

## Step 10: Check the Result

Each side now holds the other's folder as an encrypted backup:

```bash
# Buddy 1's backup, as stored on Buddy 2
find /tmp/buddy2/.buddydrive/storage -type f

# Buddy 2's backup, as stored on Buddy 1
find /tmp/buddy1/.buddydrive/storage -type f
```

Under `<storage>/<buddy-id>/<folder-id>/` you will see `.blob` and `.meta`
files, not your original names — that is the encryption working. The `.meta`
sidecar holds size, mode and content hash; the `.blob` holds the sealed chunks
exactly as the owner sent them.

The web GUI on either side shows the same thing under the buddy's storage
figures:

```bash
curl -s http://127.0.0.1:17521/storage
```

What this proves:

- separate homes, configs, ports and storage work
- one shared pairing code is enough to pair both sides
- two instances reach each other through `buddy-addresses` without a public IP
- the sync session completes and the backup is stored encrypted

## Step 11: Test a Real Change

Add a file on Buddy 1:

```bash
printf 'second file\n' > /tmp/buddy1/Documents/second.txt
```

A sync session runs on each dial, and every connection carries one session. Ask
the daemon for one on Buddy 1, so you do not have to wait for the interval:

```bash
curl -s -X POST http://127.0.0.1:17521/sync/docs
```

It names the folders and buddies it will dial, and whether the daemon is running:

```json
{"ok": true, "message": "Sync requested", "folders": 1,
 "buddies": [{"id": "…", "name": ""}], "daemonRunning": true, "folder": "docs"}
```

A second `.blob`/`.meta` pair then appears in Buddy 2's storage for that folder:

```bash
find /tmp/buddy2/.buddydrive/storage -name '*.blob' | wc -l   # now 2
```

Without a nudge, a session comes due on its own: every 5 minutes until the two
have made contact, then every 30 minutes. Set it per buddy when you want
something else:

```bash
HOME=/tmp/buddy1 ./bin/buddydrive config set buddy-sync-interval <BUDDY2_UUID> 2h
HOME=/tmp/buddy1 ./bin/buddydrive config set buddy-sync-window <BUDDY2_UUID> 22:00-06:00
```

The window only limits when *this* side starts a sync; incoming connections from
a known buddy are always accepted.

Watch a session as it happens, including its outcome and the bytes moved:

```bash
curl -s http://127.0.0.1:17521/sessions
```

Deleting the file on Buddy 1 removes the corresponding blob on Buddy 2 — the
owner is authoritative. Renaming it moves the blob instead of re-uploading.

## Testing Across Two Machines

For two real machines, use one of these setups:

1. **Same network** - exactly as above, with `buddy-addresses` pointing at each
   other's LAN IP. No router changes needed.
2. **Direct over the internet** - forward `listen_port` on both routers and set
   `[network].announce_addr` to each public multiaddr, then let discovery find
   both sides.
3. **Relay fallback** - both sides set the same `relay-region`; the shared
   pairing code is reused as the relay secret:

```bash
buddydrive config set api-base-url https://api.buddydrive.org
buddydrive config set relay-region eu
```

The public TCP relay is `relay-eu.buddydrive.org:41722`.

## Restore

### Restore a Missing File From Your Buddy

Once both sides sync, BuddyDrive restores missing local files as part of normal
sync:

1. A file exists in Buddy 1's folder
2. The same file is missing from Buddy 1's disk later (lost, deleted by accident)
3. The next successful sync recreates it, verified by content hash

A file the buddy has and you do not is only *deleted* when your index shows you
held that path before; otherwise it is fetched. That is what makes restore onto
an empty machine pull files down instead of wiping the buddy's copy.

Append-only only protects existing local files from being overwritten. It does
not block creating a file that is missing locally.

### Restore Config On A Replacement Machine

On the original machine, set up recovery once:

```bash
./bin/buddydrive setup-recovery
```

That command generates a 12-word recovery phrase, asks you to verify part of it,
stores recovery metadata in `config.toml`, and syncs an encrypted copy of your
config to the relay.

On a replacement machine:

```bash
./bin/buddydrive recover
./bin/buddydrive start
```

Enter the same 12-word phrase. If relay recovery succeeds, BuddyDrive writes the
restored config locally. Starting the daemon then lets normal sync recreate the
missing files in your configured folders.

Current limitation: `recover` prompts for buddy fallback details if relay
recovery fails, but the buddy-backed config fetch path is not implemented yet.
Recovery works via the relay path only.

## Cleanup

```bash
HOME=/tmp/buddy1 ./bin/buddydrive stop
HOME=/tmp/buddy2 ./bin/buddydrive stop
rm -rf /tmp/buddy1 /tmp/buddy2
```

## Troubleshooting

1. **`Address already in use` on startup**

Set different `listen_port` values in each config, and use different `--port`
values when starting the daemons.

2. **`buddydrive status` shows buddies as offline**

Expected. The CLI reads configured state; it does not query the running daemon
for live connection state. Use the web GUI or `GET /buddies` on the control API
for that.

3. **`buddydrive start --daemon` stays in the foreground**

Expected. Background daemon mode is not implemented. Use `Ctrl+C`,
`buddydrive stop`, or a systemd unit.

4. **`buddydrive connect` does not dial**

Correct. The command is a placeholder that prints guidance; manual direct
dialing is not implemented.

5. **`buddydrive init --with-recovery` only prints help**

The flag is in the help text but not parsed yet. Use `init` then
`setup-recovery`.

6. **Encrypted folder files appear as opaque blobs on the buddy's machine**

Expected, and the point of the encryption. When `encrypted = true` (the
default), file names and content are both sealed before the buddy ever sees
them.

7. **The two sides connect but "Folder sync finished" never appears**

Check that the folder is actually readable. A folder that cannot be fully read
is skipped for that session (so an unplugged disk cannot be mistaken for an
empty folder and delete the backup); the log says why.
