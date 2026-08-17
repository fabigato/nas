# Drive-pull test — `tank`

First run 2026-08-17. Re-run after any change to the enclosure, cabling, or OpenZFS
version: the behaviour documented here is a property of the JMicron bridge firmware,
not of ZFS, so it can change underneath you.

Full write-up and conclusions live in `~/repos/obsidian/nas.md` under
"The drive-pull test (2026-08-17)". This file is just how to repeat it.

## Result in one line

Pulling one drive from the redundant mirror **suspends the whole pool**
(`SUSPENDED`, not `DEGRADED`) because the bridge re-enumerates and drops both SCSI
LUNs at once. No data loss; recovery is a single `zpool clear`.

## Files

| File | What |
| --- | --- |
| `baseline-pre-pull.txt` | Pool/dataset/property state before the test |
| `watch-pull.sh` | Observation harness — logs pool + device state on every change |
| `pull-event.log` | What the 2026-08-17 pull actually produced |
| `manifest-sha256.txt` | sha256 of the test blobs, taken **before** the pull |
| `manifest-sha256-post-pull.txt` | Same hashes re-taken after recovery (identical) |

## Procedure

Do this **only with disposable data on the pool.** It is safe — but "safe" here means
"the pool survives", not "nothing goes offline". The pool *will* go fully offline.

1. **Write disposable, incompressible test data** so the scrub and any resilver have
   something real to chew on. Incompressible matters: with `lz4` on `tank/media`,
   compressible data makes the on-disk numbers a lie.

   ```bash
   mkdir -p /Volumes/tank/media/pulltest
   for i in $(seq -w 1 10); do
     openssl enc -aes-256-ctr -pass "pass:pulltest-$i" -nosalt -in /dev/zero 2>/dev/null \
       | head -c $((2*1024*1024*1024)) > /Volumes/tank/media/pulltest/blob-$i.bin
   done
   ```

   Use `head -c`, **not** `dd bs=1m count=N`. `dd` reading from a pipe counts short
   reads as whole blocks, so it silently writes a fraction of what you asked for.

2. **Take the manifest before pulling anything.** Use `openssl dgst` — `shasum` is
   Perl and far slower over 20 GiB.

   ```bash
   cd /Volumes/tank/media/pulltest
   for f in blob-*.bin; do openssl dgst -sha256 -r "$f"; done > manifest-sha256.txt
   ```

3. **Start the watcher**, then confirm it captured a clean `ONLINE` baseline before
   touching hardware.

   ```bash
   sh -n watch-pull.sh    # staged-review pattern, same as the boot unlock
   nohup sh watch-pull.sh "$PWD/pull-event.log" >/dev/null 2>&1 &
   ```

4. **Pull a drive from a known bay.** Bay 1 = SCSI LUN 0 = `USB30_DISK00`,
   bay 2 = LUN 1 = `USB30_DISK01` (verified 2026-08-17, but re-verify — that's the point).

5. **Expect the pool to suspend.** Anything touching `/Volumes/tank` will now *hang*
   rather than error, because `failmode=wait`. Don't fight it and don't `kill -9`
   things; it releases on `zpool clear`. `zpool status` itself stays responsive.

6. **Reseat the drive**, wait for its LED, then clear:

   ```bash
   sudo /usr/local/zfs/bin/zpool clear tank
   ```

   Returns instantly, no output. Datasets remount themselves.

7. **Verify, two independent ways.** The auto-scrub zedlet
   (`resilver_finish-start-scrub.sh`) is enabled but did **not** fire — run it yourself.

   ```bash
   cd /Volumes/tank/media/pulltest
   for f in blob-*.bin; do openssl dgst -sha256 -r "$f"; done > /tmp/verify-post.txt
   diff -u manifest-sha256.txt /tmp/verify-post.txt && echo PASS
   sudo /usr/local/zfs/bin/zpool scrub tank      # ~96 MB/s; watch with zpool status
   ```

8. **Delete the blobs** when done.

## Gotchas found the hard way

- **`zpool status` will not tell you which bay died.** Both members stay `ONLINE`;
  only the error counters move. Identify the bay by the **missing** symlink in
  `/var/run/disk/by-serial/`.
- **Device nodes shuffle.** The surviving drive moved `/dev/disk5` → `/dev/disk4`
  mid-test. Never key anything on `/dev/diskN`.
- **`zpool events` needs root**, so this harness can't read it — hence the reliance on
  zed's log at `/private/var/log/org.openzfsonosx.zed.err`, which is mode 644.
- **Enclosure LEDs are presence, not fault.** No SES on this bridge, so
  `ZED_USE_ENCLOSURE_LEDS=1` is inert. A dark LED just means an empty bay.
- **`timeout` doesn't exist on macOS.** Don't reach for it when guarding against hangs.
- **No real resilver is obtainable here.** Because the pool suspends instead of
  degrading, nothing can be written while a drive is out, so the members never diverge.
  Expect a few hundred KB, not gigabytes.
