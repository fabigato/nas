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
| `scripts/nas-backup/` | Replication to an offline, independently-encrypted pool |
| `tests/` | Test harnesses — see [Tests](#tests) |

Each script carries a long header comment explaining its own design decisions.
This README is the map; the headers are the detail.

## The pool

Three datasets, all inheriting `compression=lz4`, `atime=off`, `xattr=sa` and
`dnodesize=auto` from the pool root. The root itself is `canmount=off` — it
exists to hold properties the children inherit, and holds no data.

| Dataset | recordsize | Purpose | Snapshot retention |
| --- | --- | --- | --- |
| `tank/my_media` | 1M | Irreplaceable photos and video | 8 weekly + 6 monthly |
| `tank/media` | 1M | Re-downloadable media | 2 weekly |
| `tank/documents` | 128K | Small mixed files | 7 daily + 4 weekly + 6 monthly |

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

## The offline backup — `tank-backup.sh`

**Not a daemon, and there is no plist.** The destination drive is meant to be
disconnected, which is the whole point: a backup that is always attached is an
online second copy, reachable by the same `rm -rf`, the same ransomware and the
same power event as the original. So this runs by hand, attended, when the drive
is plugged in — which is also what lets the destination pool use
`keylocation=prompt` and keep no key on disk at all.

```sh
sudo sh scripts/nas-backup/tank-backup.sh --dry-run   # decide, change nothing
sudo sh scripts/nas-backup/tank-backup.sh --export    # sync, then export
```

Exit codes: `0` synced, `1` refused, `2` a send/receive failed, `3` nothing to do.

**Non-raw `zfs send`, into a pool with its own encryption key.** Raw send (`-w`)
of encrypted datasets is the historically buggiest corner of native ZFS
encryption; non-raw sidesteps that path, and since both ends are the same machine
on the same build there is no version skew to worry about. The destination
re-encrypts under its own key, so the two pools share no key material —
`encryptionroot` on a received dataset reads as the destination pool, not the
source.

The consequence that decides whether the backup is worth anything: **the
destination passphrase must be recoverable without the source machine.** The
scenario an offsite drive exists for is that machine being destroyed or stolen.

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

Worth knowing if you ever debug this: **`zfs get readonly` on a *mounted* dataset
can report the mount's state rather than the stored property.** Always check
`zfs get -o all readonly <dataset>` and look at the `source` column; a `local`
source of `on` means the property is fine and only the live mount is writable.
Reading the value alone will convince you the backup is exposed when it isn't.

**Known limit:** `recv -F` makes the destination mirror the source's snapshot
history rather than exceed it. Delete a file, let retention prune the snapshot
holding it, then sync, and both copies are gone. Deep retention on the
irreplaceable dataset is what keeps that window wide.

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
