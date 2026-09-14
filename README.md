# nas — an encrypted OpenZFS mirror on macOS

Operational scripts for a DIY NAS: an encrypted OpenZFS pool called `tank`, on a
mirrored pair of drives in a USB enclosure, running on a Mac.

macOS has no native ZFS and no `systemd`, so the three things a Linux ZFS box
gets for free — importing an encrypted pool at boot, scheduling scrubs, and
scheduling snapshots — all have to be built. That is what this repo is. Each
piece is a `LaunchDaemon` plus a plain `/bin/sh` script, deliberately with no
shared library between them, so a mistake in one cannot take the others down.

Everything here assumes the OpenZFS-on-macOS fork with binaries in
`/usr/local/zfs/bin/`.

## What's here

| Path | What it is |
| --- | --- |
| `scripts/nas-boot-unlock/` | Imports and unlocks `tank` at boot |
| `scripts/nas-scrub/` | Monthly scrub, with guards and Discord alerting |
| `scripts/nas-snapshot/` | Daily snapshots with tiered retention |
| `scripts/nas-backup/` | Creating the offline backup pool, and replicating to it |
| `scripts/nas-jellyfin/` | The media server the pool exists to serve |
| `tests/` | Test harnesses — see [Tests](#tests) |

Each script carries a long header comment explaining its own design decisions.
This README is the map; the headers are the detail.

## The pool

Three datasets, all inheriting `atime=off`, `xattr=sa` and `dnodesize=auto` from
the pool root, which also hands down `compression=lz4`. The root itself is
`canmount=off` — it exists to hold properties the children inherit, and holds no
data.

| Dataset | recordsize | compression | Purpose | Snapshot retention |
| --- | --- | --- | --- | --- |
| `tank/my_media` | 1M | lz4 | Irreplaceable photos and video | 8 weekly + 6 monthly |
| `tank/media` | 1M | lz4 | Re-downloadable media | 2 weekly |
| `tank/documents` | 128K | **zstd** | Small mixed files | 7 daily + 4 weekly + 6 monthly |

`documents` is the one dataset that overrides compression, and it is the only one
where the override pays: zstd costs more CPU per block than lz4 and buys a real
ratio on text, which is what is in there. On the two media datasets the bytes are
already-compressed video, so zstd would spend the CPU and return nothing.

**The layout is organised by replaceability, and that is the whole design.** It
is what decides retention depth, and it is also what decides offsite priority.

The split between `my_media` and `media` is therefore about **policy, not
properties** — the two carry identical recordsize and compression, so on
properties alone splitting them buys nothing. One is irreplaceable and gets deep
retention; the other can be re-downloaded and gets two snapshots of insurance
against a mistyped `rm`. A dataset that can't be placed on that axis probably
shouldn't exist, because there's no principled retention number to give it.

## The daemons

All three are `LaunchDaemons` in `/Library/LaunchDaemons`. Each writes a durable
log under `/var/log/` and communicates its outcome through its exit code, so
`launchctl print system/<label> | grep 'last exit'` is enough to know where you
stand.

### Boot unlock — `local.tank-boot-unlock`

Imports `tank` and loads its encryption key at boot, replacing the stock OpenZFS
auto-import (which is switched off via `/etc/zfs/noautoimport`). Retries, because
a USB enclosure is not always enumerated by the time the daemon first runs.

Devices are referenced by `/var/run/disk/by-serial/` rather than by device node
or by GPT UUID. This is not cosmetic: device nodes move when a USB bridge
re-enumerates, and UUIDs are unreadable at the moment you most need to know which
physical bay a drive is in. **Edit `DISK0` and `DISK1` in the script to your own
`by-serial` names before installing.**

`zsysctl.conf` caps the ARC. OpenZFS defaults to half of RAM, which is too much
on a machine that does anything else. Note that the writable tunable is
`kstat.zfs.darwin.tunable.zfs_arc.max`; `kstat.zfs.misc.arcstats.c_max` is a
read-only statistic — set the first, verify the second.

This is the only component that needs **Full Disk Access**, because it opens raw
devices to import the pool. Grant it to `/usr/local/zfs/bin/{zpool,zfs,zdb}`.

### Scrub — `local.tank-scrub`

Monthly, 1st at 03:00. A scrub reads every allocated block on both mirror members
and verifies it against its checksum, rewriting anything that fails from the good
copy. On a USB enclosure where SMART is unavailable, this is the only proactive
health check available at all.

Monthly rather than weekly because a full scan of a multi-TB pool over USB runs
for many hours; weekly would leave the drives scanning a large fraction of their
lives.

It is a scheduler with guards, not a reporter — `zed` owns scrub *results* via
`scrub_finish-notify.sh`. This script reports its own *failures*, which zed
structurally cannot see, because zed only speaks when a scrub finishes and says
nothing about a scrub that never started.

The guards: it refuses to scrub a pool that is not `ONLINE` or `DEGRADED`, skips
if a scan is already running, bails out of its watch loop if the pool changes
state mid-scrub, and never runs `zpool clear` automatically — error counters are
cumulative, so it reports its findings as a delta against the pre-scrub baseline
rather than destroying evidence nobody has looked at yet.

Exit codes: `0` clean, `1` refused to start, `2` errors found, `3` a scan was
already running, `4` stopped watching but the scrub continues.

### Snapshot — `local.tank-snapshot`

Daily, 02:00. One job drives all three retention tiers.

**A tier is due based on the age of the newest snapshot in that tier, not on the
calendar.** There is no `Weekday` or `Day` key in the plist. `launchd` runs a
missed `StartCalendarInterval` job once at the next wake, so a "weekly on Sunday"
plist plus an is-it-Sunday check would silently skip the weekly tier for as long
as the machine happened to be asleep on Sunday mornings. Age-based due-ness has
no such hole, and it makes the script idempotent — run it twice and the second
run correctly does nothing.

**It skips the snapshot when nothing has been written**, checked per tier via
`zfs get written@<snap>`. This turns "keep 8 weekly" from *8 weeks of history*
into *the last 8 states the dataset was in*, which on a dataset edited twice a
year is the difference between eight weeks of coverage and years of it, at
identical cost. The check must be per tier: the plain `written` property compares
against the newest snapshot of any tier, so on a dataset with a daily tier the
weekly tier would conclude nothing had changed and never advance again.

The check fails **open** — if the property cannot be read, the snapshot is taken.
A spurious snapshot costs a few KB of metadata; a skipped one can cost data.

**The pruner only ever considers snapshots it created.** Names are
`<dataset>@auto-<tier>-<YYYY-MM-DD-HHMMSS>` and the pruner anchors on that shape,
so it cannot destroy a hand-made snapshot or a replication base. On a failed
destroy it asks `zfs holds` — structurally, rather than parsing the error text,
which differs between OpenZFS implementations — and treats a held snapshot as an
expected skip rather than a failure. It never passes `-d`, which would defer the
destroy until the hold was released.

Exit codes: `0` ran, `1` refused (pool not imported or not healthy), `2` an
operation failed, `3` a configured dataset does not exist.

Retention is configured at the bottom of the script as one line per dataset —
keep counts per tier, `0` to disable a tier.

## The offline backup — `tankbak-create.sh`, then `tank-backup.sh`

**Not a daemon, and there is no plist.** The destination drive is meant to be
disconnected, which is the whole point: a backup that is always attached is an
online second copy, reachable by the same `rm -rf`, the same ransomware and the
same power event as the original. So this runs by hand, attended, when the drive
is plugged in — which is also what lets the destination pool use
`keylocation=prompt` and keep no key on disk at all.

### A spare bay in the Orico is fine — the care is at removal

Both `tank` members hang off the same USB port. `diskutil info -plist` reports an
identical `DeviceTreePath` for each, because the enclosure presents two LUNs
behind one bridge:

```
IODeviceTree:/arm-io@.../pcie-xhci-ss-port1@08100000/usb3-hub-port3@08130000
```

**That does not disqualify a spare bay, and an earlier version of this section
said it did.** The wrong reasoning is worth recording because it was persuasive:
it borrowed the "a backup that is always attached is an online second copy"
argument, which is about a drive that *lives* in the enclosure, and applied it to
one that sits in a bay for the length of a sync and in a drawer the rest of the
month. It also cited `tests/2026-08-17-drive-pull/` — but that test pulled an
**in-use mirror member of an imported pool**, and extending it to an exported
non-member was an extrapolation, not evidence.

On the ZFS question there is nothing to worry about: the drive joins no vdev,
`tank`'s topology is unchanged, and `zpool create` touches only the device named.

**The real consequence is at removal.** A device-removal event can make a
single-bridge enclosure re-enumerate, and if that drops `tank`'s LUNs too then
`tank` suspends — `failmode=wait`, so Jellyfin blocks in an ioctl `SIGKILL`
cannot free. Recoverable, not dangerous. Two ways to handle it:

```sh
# A — pull it and repair if needed. Try this first.
sudo sh scripts/nas-backup/tank-backup.sh --export
# remove the backup drive
sudo /usr/local/zfs/bin/zpool clear tank      # ONLY if tank suspended

# B — no risk, more steps. Switch to this if A ever disturbs tank.
sudo sh scripts/nas-backup/tank-backup.sh --export
sudo launchctl bootout system/local.jellyfin
sudo /usr/local/zfs/bin/zpool export tank
# power the enclosure off, remove the drive, power it on
sudo launchctl bootstrap system /Library/LaunchDaemons/local.jellyfin.plist
```

In B, `tank` returns on its own: `tank-boot-unlock.sh`'s `WatchPaths` fires when
the disks reappear, which is exactly what it was added for.

The argument for a separate dock is therefore **ergonomics, not safety** — one
USB cable means unplugging is a single motion rather than a procedure. Worth
knowing, not worth blocking on. `tankbak-create.sh` reports which case you are in
and prints the matching removal steps; it does not refuse either.

### Creating the pool — `tankbak-create.sh`

`tank-backup.sh` replicates into a pool that already exists; it does not create
one. Creation is its own script because **every decision it makes is permanent
for the life of the pool** — `ashift`, the cipher, the encryption root, the key
format, the key location. None of those is a property edit later; getting one
wrong means destroying the pool and re-sending every byte over USB.

```sh
sudo sh scripts/nas-backup/tankbak-create.sh --list              # eligible targets
sudo sh scripts/nas-backup/tankbak-create.sh --dry-run <serial>  # print the plan
sudo sh scripts/nas-backup/tankbak-create.sh <serial>            # create it
sudo sh scripts/nas-backup/tankbak-create.sh --key-from-tank <serial>
```

Exit codes: `0` created, `1` refused, `2` created but a post-create check failed.

**It is mostly refusals, and it is the only script here that can destroy data
that isn't its own.** The target is named explicitly by serial and typed back to
confirm — there is no auto-detect, because "the external drive that isn't part of
`tank`" is also the description of somebody's Time Machine disk on the one day it
happens to be plugged in. It then refuses a target that is internal, virtual, a
member of an imported pool, or smaller than `tank`'s allocated bytes. Sharing
`tank`'s enclosure is reported rather than refused, per above.

Two of those guards are less obvious than they look. **Internal** is checked
instead of trying to identify the boot disk, because on APFS that means chasing
a synthesized container back to its physical store — `/` reports `disk3` while
the data is on `disk0`, so the obvious check passes while proving nothing.
**Virtual** blocks a leftover 8 TB disk image that has been attached to this
machine since the pool build and reports its media name as `tank`.

Afterwards it reads back the properties that cannot be changed later, asserts
`feature@large_blocks` is on — without it the 1M records from both media datasets
will not send, which would surface as a refused stream hours in — and then does
the one check nothing else can do, described next.

### Encryption: independent key, shared passphrase

**Non-raw `zfs send`, into a pool with its own encryption root.** Raw send (`-w`)
of encrypted datasets is the historically buggiest corner of native ZFS
encryption; non-raw sidesteps that path, and since both ends are the same machine
on the same build there is no version skew to worry about. It would also mean
`zfs change-key` on `tank` breaking every future incremental. The destination
re-encrypts under its own key, so the two pools share no key *material* —
`encryptionroot` on a received dataset reads as the destination pool, not the
source.

**The passphrase, however, is deliberately the same one `tank` uses.** One secret
to remember, and therefore one secret to keep recoverable. Be precise about the
cost rather than repeating that the pools are "independent": independent master
keys mean `change-key` on one side doesn't touch the other, and that a corrupted
or brute-forced pool implies nothing about its counterpart. They do **not** mean
independent failure against a leaked passphrase. That is the part traded away,
knowingly — and it is a small trade, because `tank`'s passphrase already sits in
a file on an internal SSD that is not yet FileVault-encrypted, so it was never
the strong link in the source's chain either.

`keylocation=prompt`, though, and *not* `tank`'s keyfile. `tank` keeps a key on
disk because it has to — a pool that must return after an unattended reboot
cannot prompt. This pool has the opposite requirement, so nothing on the Mac
unlocks it and stealing the Mac does not hand over the backup. The consequence is
the feature: this pool **cannot** be synced unattended.

**`zpool create` asks for the passphrase twice, so it catches a typo — it cannot
catch you confidently typing a *different* passphrase twice.** The pool would be
fine, importable, and locked behind a secret nobody wrote down, and you would
find out at the restore. So after creating, `tankbak-create.sh` unloads the key
and reloads it with `-L` pointed at `tank`'s keyfile, which overrides the locator
for one invocation without touching the stored property. If that load succeeds,
the passphrase provably matches `tank`'s.

Note that `tank` itself is `keyformat=passphrase` with
`keylocation=file:///etc/zfs/keys/tank.key` — the two properties are
independent, which is a standing source of confusion. The key material *is* a
passphrase; it simply lives in a file rather than being typed, because a pool
that must return after an unattended reboot cannot prompt. Whatever is in that
file is the passphrase.

**`--key-from-tank` is the safer route when that passphrase is a long random
string.** It creates the pool with `keylocation` pointed at `tank`'s key file, so
the passphrase is read rather than retyped, then immediately sets
`keylocation=prompt`. `keyformat` is immutable but `keylocation` is not, so the
end state is identical to having typed it — and the passphrase matches `tank`'s
by construction rather than by luck. The flip is treated as a hard failure if it
does not take, because a backup pool still pointing at `tank`'s key file would
keep working silently while quietly negating the paragraph above.

What the flag skips is the rehearsal — you never prove you can reproduce the
passphrase by hand. Do that in the restore test, which prompts for it anyway and
is the right place for that failure to surface.

The consequence that decides whether the backup is worth anything: **the
destination passphrase must be recoverable without the source machine.** The
scenario an offsite drive exists for is that machine being destroyed or stolen.
Sharing the passphrase with `tank` does not relax that requirement — it
concentrates it into a single secret.

### Syncing — `tank-backup.sh`

```sh
sudo sh scripts/nas-backup/tank-backup.sh --dry-run   # decide, change nothing
sudo sh scripts/nas-backup/tank-backup.sh --export    # sync, then export
```

Exit codes: `0` synced, `1` refused, `2` a send/receive failed, `3` nothing to do.

**This is a true sync, not an accumulating archive.** New files appear on the
destination, deleted files disappear from it: `recv -F` rolls the destination
forward to match the source exactly rather than keeping what the source no longer
has. That is the intended behaviour, and its flip side is the known limit at the
end of this section.

**It takes its own `sync-` prefixed snapshots** rather than reusing the retention
tiers, because there is no single pool-wide name to use as a base — the snapshot
daemon's names are per-dataset and per-tier. The prefix also means the retention
pruner, which anchors on `auto-`, is structurally incapable of destroying an
incremental base. The script additionally places a `zfs hold`, as a second line
of defence rather than the primary one.

**Per-dataset sends, not `send -R` from the pool root**, so the destination's own
root dataset — which is its encryption root — is never a receive target. The cost
is no cross-dataset atomicity, which is not worth buying for independent datasets
with no transactional relationship.

**`recv -s`** leaves a resume token if a transfer is interrupted, rather than
discarding the work. Immaterial on megabytes, decisive on terabytes over USB. To
abandon a partial receive instead: `zfs recv -A <dataset>`.

The destination gets `failmode=continue` rather than `tank`'s `wait` — for the
backup pool a yanked drive should fail the receive and be retried, not hang in an
ioctl that `SIGKILL` cannot free.

**The destination datasets are unmounted before `readonly=on` is set**, and the
property is read back afterwards, on every run including one that finds nothing
to send. Nothing should be mounted there in normal operation — `recv -u` leaves
them alone — so a mount means something else left one behind.

**A mounted destination cannot be received into**, and that single fact has now
caused two separate failures. `zfs recv` reports `dataset is busy` and the send
dies. Two defences, because the mount has arrived by two different routes:

- **Every receive passes `-u`.** The resume path did not until 2026-09-14, and
  the asymmetry was invisible until a resume ran against real data: the run
  resumed 424 GB of `my_media` over 1h31m, mounted it on completion, then failed
  its 2.4 MB follow-up incremental three seconds later, while `media` and
  `documents` sailed through. One missing flag, three hours in.
- **Each destination dataset is unmounted before it is received into.** This
  covers a mount that arrived some other way — the restore test left some behind
  on 2026-08-23, and macOS will happily auto-mount a volume that appears while
  Finder is watching. It warns rather than refusing, since the receive below
  fails loudly and more specifically on its own.

Worth knowing if you ever debug this: **`zfs get readonly` on a *mounted* dataset
can report the mount's state rather than the stored property.** Always check
`zfs get -o all readonly <dataset>` and look at the `source` column; a `local`
source of `on` means the property is fine and only the live mount is writable.
Reading the value alone will convince you the backup is exposed when it isn't.

**Known limit:** `recv -F` makes the destination mirror the source's snapshot
history rather than exceed it. Delete a file, let retention prune the snapshot
holding it, then sync, and both copies are gone. Deep retention on the
irreplaceable dataset is what keeps that window wide. This is the cost of the
sync being a true sync rather than an archive, and it is the reason the retention
depth on `my_media` is the number it is.

### The first destination pool, and how it was lost

Worth reading before trusting the second one, because the cause was us and not
the hardware.

The first `tankbak` lived on a small stand-in device, `STORAGE_DEVICE-7423J07`.
It was created, synced three times and restore-tested clean on 2026-08-23. By
00:18 the next morning it was unimportable:

```
pool: tankbak   state: FAULTED
status: The pool metadata is corrupted.
```

The timeline is the explanation. The last good sync finished 23:18:52 and the
drive was unplugged before 23:41 — and at that point `tank-backup.sh` only
honoured `--export` on its happy path. Five exit paths, including the ordinary
nothing-to-send one, returned with the pool still **imported**. So the drive was
almost certainly pulled while ZFS held it, which is the drive-pull test performed
by accident. Commit `55adeb1` closed that hole; `maybe_export` is now called on
every exit path that got far enough to import.

Two standing rules follow:

- **Always `--export`, and wait for it to return, before unplugging.** It is the
  one operational rule this pool's survival depends on. A partial receive
  survives an export — ZFS is transactional and the resume token is durable — so
  there is never a reason to skip it for convenience.
- **Scrub the destination after the first full send, and periodically after.** A
  single-drive pool has no redundancy, so ZFS can detect corruption there but
  never repair it. Finding out the drive is bad while `tank` still holds the only
  good copy is the entire value of the check. It is not part of the restore test
  and there is no daemon for it: `sudo /usr/local/zfs/bin/zpool scrub tankbak`.

## Jellyfin — `local.jellyfin`

The reason the pool exists. Serves `tank/media` and `tank/my_media` over
Tailscale only, and it is the one component here that is a long-running server
rather than a scheduled job.

**Native, not Docker.** Docker on macOS runs containers in a Linux VM whose
hypervisor exposes no GPU or media engine, so a containerised Jellyfin can only
transcode in software — on a machine already sharing CPU with other work.
Running native buys VideoToolbox and the M4 Max media engine.

**A LaunchDaemon running the server binary, not the app.** Jellyfin ships on
macOS only as a menu-bar app that installs itself as a login item, and a login
item never starts on a machine with no automatic login. `brew install --cask
jellyfin` is used purely to obtain `Contents/MacOS/jellyfin` and the bundled
VideoToolbox-enabled ffmpeg; the Cocoa wrapper is ignored.

**The wrapper's job is to refuse.** Jellyfin treats a library path that has gone
missing as a library that has been *emptied*, so a scan against an unmounted
`/Volumes/tank` would purge its database of every item, and with it all watch
state and user data. `jellyfin-server.sh` therefore polls for a healthy, mounted
pool and exits nonzero rather than starting blind. `KeepAlive` then makes that
self-healing: launchd retries, so the server comes up on its own once the
enclosure is switched back on, without duplicating the `WatchPaths` logic in the
boot unlock. It asks `zpool list` before touching any dataset, because
`failmode=wait` means a suspended pool hangs anything that reaches for it.

**Every writable path is on the internal SSD**, under `/usr/local/var/jellyfin`.
Transcode scratch is the reason — it is large, constantly rewritten, and both
media datasets are snapshotted, so scratch on `tank` would be captured by the
next nightly snapshot and inflate `usedbysnapshots` permanently.

`config-seed/` holds the starting configuration. Two settings are seeded rather
than clicked in afterwards because both are wrong by default in ways that do not
announce themselves:

- **`network.xml` binds the listener to `127.0.0.1`.** Jellyfin's compiled-in
  default is `0.0.0.0` and it does not write this file until something changes
  it, so configuring after first start would leave a window where an
  unconfigured server with an open setup wizard is reachable on the LAN. A
  loopback bind is what makes the exposure tailnet-only *structurally* — there
  is simply no socket on the LAN interface — rather than depending on a firewall
  rule or on Serve staying configured. UPnP and UDP autodiscovery are off.
- **`encoding.xml` sets `HardwareAccelerationType` to `videotoolbox`.** It ships
  as `none`, which would have made the entire native-over-Docker decision
  worthless while looking like a working install.

Exposure is `tailscale serve`, never `tailscale funnel`, on its own port —
`:8443` already belongs to ComfyUI.

## Install

The repo is the source of truth but installs are manual, so **`diff` before
editing** — the installed copy and the repo copy can drift.

```sh
# Review first
sh -n scripts/nas-snapshot/tank-snapshot.sh
diff -u /usr/local/sbin/tank-snapshot.sh scripts/nas-snapshot/tank-snapshot.sh

# Then install
sudo install -m 755 -o root -g wheel scripts/nas-snapshot/tank-snapshot.sh /usr/local/sbin/
sudo install -m 644 -o root -g wheel scripts/nas-snapshot/local.tank-snapshot.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/local.tank-snapshot.plist
```

Same pattern for the other two. Log rotation is one file covering all of them:

```sh
sudo install -m 644 -o root -g wheel scripts/nas-scrub/tank.newsyslog.conf /etc/newsyslog.d/tank.conf
sudo newsyslog -C -f /etc/newsyslog.d/tank.conf
```

Rotation is size-triggered rather than time-triggered on purpose: a time trigger
rotates away a quiet month and leaves you holding empty files, when the
interesting case is a chatty failure. The `C` flag means "eligible for creation
when `newsyslog` is invoked with `-C`", not "create automatically" — a plain run
skipping a file that doesn't exist yet is normal.

Rollback is symmetrical:

```sh
sudo launchctl bootout system/local.tank-snapshot
sudo rm /Library/LaunchDaemons/local.tank-snapshot.plist /usr/local/sbin/tank-snapshot.sh
```

Existing snapshots survive that, as does an in-flight scrub — ZFS persists scan
state in the pool, so a scrub even survives a reboot. To stop one:
`zpool scrub -s tank`.

## Testing

**Test under `launchctl kickstart`, never from a terminal.**

```sh
sudo launchctl kickstart -k system/local.tank-snapshot
tail -f /var/log/tank-snapshot.log
```

This is the single most important operational rule in the repo. A daemon gets no
GUI session, no user environment and a minimal `PATH`, and — the part that
actually bites — `sudo` from a terminal inherits the *terminal application's*
Full Disk Access grant. A script that works perfectly under `sudo` can fail
under `launchd` for that reason alone, and the failure looks like broken
hardware.

Verify a daemon needs no Full Disk Access by checking for denials after a run:

```sh
/usr/bin/log show --last 5m --style compact | grep 'deny(1)'
```

Expect zero hits naming `zfs` or `zpool`. Only the boot unlock legitimately needs
FDA; scrub and snapshot act on an already-imported pool through the `/dev/zfs`
ioctl, so the kernel does the disk I/O and no raw device is opened.

**Do not stop at a green exit code.** Ask what the run did *not* execute. A
kickstart of the snapshot daemon on a pool with no snapshots creates one per tier,
finds every tier under its keep count, prunes nothing, and exits 0 — leaving the
entire retention half of the script unexercised while looking like a pass. Same
for the scrub daemon's progress-logging branch, which a scrub of a nearly-empty
pool finishes too fast to reach.

`launchctl setenv` is not usable for test overrides — it mutates launchd's global
environment, which System Integrity Protection forbids. Use per-job
`EnvironmentVariables` in a plist instead, which is what the `-test.plist` files
are for. **Never leave a `-test.plist` bootstrapped**; it is an unscheduled job
that will fire on the next `bootstrap` of the system domain.

## Tests

| Directory | What it covers |
| --- | --- |
| `tests/snapshot-retention/` | Drives the snapshot pruner past its keep counts and asserts tier depths, that the survivors are the newest, prefix scoping, hold safety, and skip-if-unchanged. Run as root; creates `test-`prefixed snapshots on the live pool and cleans up on exit, including on `SIGINT` |
| `tests/scan-parse/` | Fixture tests for the scrub daemon's `zpool status` parser, over completed / in-progress / repaired / errored / canceled / resilvering / never-scanned output |
| `tests/backup-restore/` | Proves the offline backup is *restorable*, not just that the send exited 0: known payload and sha256 manifest, then cold import, passphrase, read-only mount, checksum verification and write-rejection probes. Partly manual — the physical unplug in the middle is the point and cannot be scripted |
| `tests/jellyfin-readonly/` | Asserts Jellyfin writes nothing into the media datasets, via `written@` and `zfs diff` across a full library scan. Three phases, because the scan in the middle is slow. macOS's own `.DS_Store` / Spotlight writes are classified as noise rather than failures |
| `tests/2026-08-17-drive-pull/` | Procedure, observation harness and captured logs from physically pulling a drive from the running mirror |

Two things to know before editing `tests/snapshot-retention/`:

- It calls `zpool sync`, not `sync(8)`. `written` and `written@` are on-disk
  accounting and do not move until the writes land in a synced transaction group;
  POSIX `sync(8)` does not force one. Without this the daemon correctly sees
  nothing written, skips, and the suite silently tests nothing.
- Snapshots it creates are prefixed `test-`, never `auto-`, so its namespace and
  the production pruner's provably cannot collide in either direction.

It asserts against the real retention table in the script, so the keep counts are
duplicated between the two on purpose — a disagreement means one of them is a
typo.

## Notifications

Alerts go to a Discord webhook. `zed` has no Discord backend and does not need
one: Discord webhooks expose a Slack-compatible endpoint, so appending `/slack`
to the webhook URL makes it accept the payload `zed_notify_slack_webhook()`
already sends. One line in `zed.rc`, no code.

**The `/slack` suffix is load-bearing and omitting it fails silently.** The bare
endpoint is Discord's native API, which expects `content` rather than `text`, so
it reads zed's payload as empty and returns HTTP 400. zed cannot tell: it greps
the response for Slack's nested error shape while Discord returns a flat one, and
`curl` exits 0. A rejected post is therefore counted as a delivery, and a revoked
token fails the same way with a 401.

For that reason the scripts do their own delivery rather than calling
`zed_notify()`: they read only the URL out of `zed.rc` — read, not sourced — and
check the HTTP status themselves. The channel that reports a daemon's failures
must not be one that cannot detect its own.

`ZED_NOTIFY_VERBOSE=1`, deliberately against the default of 0, so a *clean*
monthly scrub also posts. The point is not that a clean result is interesting —
it is that a channel which can die silently makes "no news is good news" unsound.
The monthly message is a heartbeat and its absence is the signal.

The snapshot daemon runs daily, where that reasoning inverts: a daily message is
noise, and noise is how a real alert gets missed. It alerts on failures, plus one
summary if the last one went out more than 30 days ago — the same heartbeat rate,
on its own timer rather than tied to a tier firing.

`zed.rc` is a **package file**: an OpenZFS upgrade overwrites it and silently
switches notifications off. `scripts/nas-scrub/zed.rc.local` is a record of what
belongs in it, not something that gets installed. Re-apply after every upgrade.

## After an OpenZFS upgrade

Three things fail silently and are worth re-checking every time:

1. The Full Disk Access grants on `/usr/local/zfs/bin/{zpool,zfs,zdb}` —
   re-signed binaries can invalidate them, and the failure looks exactly like
   dead hardware.
2. `zed.rc`, per above.
3. That the ARC cap still applies, since the stock import script is what applies
   `zsysctl.conf`.

The macOS fork also requires **Reduced Security** for its kernel extension, which
means a macOS point update can block the kext and leave the pool inaccessible
until a rebuilt package ships. Check the fork's releases before taking a major
update.

## Caveats

- **SMART does not work through a USB enclosure on macOS.** smartmontools has no
  SCSI passthrough for USB mass storage there, for any device type. So there are
  no reallocated-sector counts and no power-on hours: health rests entirely on
  `zpool status` error counters plus scheduled scrubs. That catches corruption
  that already happened, and gives no advance warning of a drive about to die.
- **`zpool status` may not name a failed drive.** On a single-bridge enclosure,
  pulling one drive can drop both LUNs at once and suspend the whole pool rather
  than degrading it — and both members can keep reporting `ONLINE` while only the
  error counters move. The reliable signal for "which drive is gone" is which
  symlink is missing from `/var/run/disk/by-serial/`. Any monitoring built on
  parsing vdev *state* will miss a real removal.
- **`failmode` is `wait`.** Anything touching a suspended pool hangs rather than
  erroring, and `SIGKILL` will not free a process blocked in an uninterruptible
  ioctl. This is why the daemons refuse to issue commands against a pool that
  isn't healthy instead of wrapping them in a timeout. Recovery from a suspend is
  `zpool clear tank` once the devices are back.
- **Snapshots are not a backup.** They live in the same pool on the same drives
  and protect against deletion, bad overwrites and ransomware — not against the
  enclosure dying, theft or fire. A snapshot on a dead pool dies with the pool.
