# Backup restore test

Proves the offline backup can be restored from. Not that the sync exited 0 —
that only proves a stream was accepted.

Four things have to hold, and only the last one is what anybody actually cares
about:

1. The destination pool imports on its own, after being exported and physically
   disconnected.
2. Its passphrase works — the destination is independently encrypted, so this is
   the only thing standing between you and an unreadable drive if the source
   machine is gone.
3. Every file matches its pre-sync checksum.
4. The destination refuses writes.

**Redo this quarterly, and after any change to `tank-backup.sh`, the enclosure,
the cabling, or OpenZFS.** It is in the standing checks in the note for that
reason.

## Procedure

The unplug in the middle is not scriptable, and is the entire point of an offline
backup, so this is deliberately half manual.

```sh
cd ~/repos/nas

# 1. Known payload and a manifest, taken BEFORE the sync.
sudo sh tests/backup-restore/test-backup-restore.sh payload

# 2. Sync, and export so the drive is safe to pull.
sudo sh scripts/nas-backup/tank-backup.sh --export
```

**3. Physically unplug the drive. Then plug it back in.**

Don't skip the unplug. An import of a pool that never left the machine proves
much less: the disk cache is warm, the device node is unchanged, and macOS has
not had to re-enumerate anything. The failure this step catches is a destination
that only works while it is already attached.

```sh
# 4. Cold import, load the key, mount read-only, verify every checksum.
sudo sh tests/backup-restore/test-backup-restore.sh verify

# 5. Tidy up. The next sync propagates the deletion to the destination.
sudo sh tests/backup-restore/test-backup-restore.sh cleanup
sudo /usr/local/zfs/bin/zpool export tankbak
```

Expect `passed 17, failed 0` — 1 import, 1 key load, 3 mounts, 9 checksums
(3 datasets × 3 files), 3 write probes. The count moves with `FILES_PER_DS`;
what matters is `failed 0`.

## What each failure means

| Failure | What it actually tells you |
| --- | --- |
| Could not import | The pool was not cleanly exported, or the drive did not re-enumerate. Check `zpool import` with no arguments to see what the system can find |
| Could not load the key | Wrong passphrase, or `keylocation` was changed. **There is no recovery from a genuinely lost passphrase** |
| Could not mount | `recv -u` leaves datasets unmounted by design, so this is a real fault rather than the expected state — check `mountpoint` and whether the directory is occupied |
| Checksum mismatch | The serious one. A stream was accepted and the bytes are wrong. Do not overwrite the source's snapshots; investigate before syncing again |
| Missing on destination | The dataset was replicated but that file was not in the stream — likely the payload was written after the snapshot the sync sent |
| Accepted a write | `readonly=on` is not in effect, so something other than the sync script can modify the backup |

## A note on the manifest

It lives at `/var/tmp/tank-restore-manifest.txt`, not in this directory, because
it describes random bytes and has no business in version control. It records
**dataset-relative** paths, so the same manifest verifies against the
destination's different mountpoints with no rewriting — which is also what makes
it usable for a restore onto a rebuilt pool later.

## What this test does not cover

- **Restoring the whole pool onto new hardware.** This verifies the backup is
  readable, not that a full `zfs send` back into a fresh `tank` works. That is a
  bigger exercise and worth doing once, cheaply, while the pool is nearly empty.
- **Bit rot on the destination.** The backup pool is a single drive with no
  redundancy, so ZFS can detect corruption there but cannot repair it. A scrub of
  the destination while it is attached is the check for that, and it is not part
  of this test.
- **The deletion-then-sync gap.** `recv -F` makes the destination mirror the
  source's history rather than exceed it, so deleting a file, letting retention
  prune the snapshot holding it, and then syncing loses both copies. The
  `cleanup` phase is a chance to watch that mechanism work on data you don't
  care about.
