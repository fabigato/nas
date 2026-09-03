# jellyfin-readonly

Asserts that Jellyfin writes nothing into `tank/media` or `tank/my_media`.

```sh
sudo sh test-jellyfin-readonly.sh baseline
sudo sh test-jellyfin-readonly.sh scan      # or scan by hand from the dashboard
sudo sh test-jellyfin-readonly.sh verify
sudo sh test-jellyfin-readonly.sh clean
```

Exit codes: `0` clean, `1` usage or precondition failure, `2` writes detected.

`scan` needs no root — it is one HTTP request — and **`sudo` scrubs the
environment**, so `sudo sh … scan` cannot see `JELLYFIN_API_KEY`. Run it without
sudo, or with `sudo -E`. Skipping it entirely and triggering the scan from
Dashboard → Scheduled Tasks is equally valid; the guard below does not care how
the scan started.

## The guard against a vacuous pass

`verify` refuses to report success unless a library scan actually completed
between `baseline` and `verify`.

This exists because the first real run of this suite passed without testing
anything. The `scan` step aborted on a missing API key, nobody noticed, and
`verify` reported `written: 0B — PASS`. Which was true, and meaningless: nothing
had run, so of course nothing was written. A test that reports success when it
exercised nothing is worse than no test, because it converts an open question
into a settled one.

So `baseline` records how many scans had completed at baseline time, and
`verify` requires that number to have gone up. It counts occurrences of
`"Scan Media Library" Completed` in Jellyfin's own log rather than parsing
timestamps — no date arithmetic in `/bin/sh`, and it is indifferent to whether
the scan came from the API, the dashboard button or the nightly schedule.

It fails **closed** in both ambiguous directions. A baseline written before this
guard existed is rejected rather than assumed fine, and a scan count that went
*down* — which happens when Jellyfin's daily log rotation drops the older file
mid-test — is treated as "cannot tell", not as a pass.

## Why this exists as a test rather than a setting

Jellyfin has no read-only mode. "Read-only libraries" is an emergent property of
several unrelated settings — the global metadata path, per-library artwork
saving, per-library subtitle extraction, which metadata savers are enabled — any
of which can be turned back on by a library-creation dialog, a plugin, or a
version upgrade that introduces a new writer with a helpful default.

So the test asserts the property instead of auditing the settings. `zfs
written@<snapshot>` and `zfs diff` answer "did anything change in this dataset"
exactly, and that answer stays valid against settings that do not exist yet.

The cost of getting this wrong is not untidiness. Both datasets are snapshotted
nightly, and `tank/my_media` carries the deepest retention in the pool — 8
weekly plus 6 monthly. A writer that rewrites metadata on every scan pins the
superseded blocks into every one of those snapshots, so `usedbysnapshots` grows
without bound on the one dataset that is irreplaceable. That is also why the
snapshot daemon's skip-if-nothing-written guard matters here: a chatty Jellyfin
would defeat it, turning a dataset that should snapshot a handful of times a
year into one that snapshots every night.

## What counts as a failure, and what does not

`written@` alone cannot be the assertion, because macOS writes to any volume it
can see and none of it is Jellyfin's doing. `zfs diff -F` is used instead, and
the type column lets a modified *directory* — a touched mtime, the consequence
of noise inside it — be told from a modified *file*.

Ignored, and reported as `noise`:

| Path | Written by |
| --- | --- |
| `.DS_Store` | Finder, on any folder it displays |
| `.Spotlight-V100/` | `mds`, indexing the volume |
| `.fseventsd/` | The filesystem events daemon |
| `.TemporaryItems/`, `.Trashes/` | Finder |
| `.VolumeIcon.icns` | Written once at pool creation |

Everything else is a `WRITE` and fails the run.

**Close any Finder window showing `/Volumes/tank` before running this.** Finder
writes `.DS_Store` on display, not on change, so browsing the library mid-test
manufactures noise entries. They will be classified correctly, but a clean run
is easier to read than a correct one full of distractions.

### `written@` keeps moving after the test passes — that is not a regression

Measured on 2026-09-03, right after a clean pass: `verify` reported `0B` on both
datasets, and eight minutes later `written@` on `tank/my_media` read **812K**. No
Jellyfin activity in between. The cause was a single `.DS_Store` touched by
Finder at 02:50.

Two things worth taking from that.

**Do not re-read `written@` later and interpret it as the test result.** The
number is only meaningful at the instant `verify` runs. macOS keeps writing to
any volume it can see, so on a long-lived snapshot it climbs on its own.

**The amplification is the real lesson.** That `.DS_Store` is 8,196 bytes and it
cost **812K** of `written` — about 100×. `recordsize=1M` is right for the video
this dataset exists to hold and brutal for an 8 KB file rewritten on every Finder
visit, because the rewrite dirties a full record plus the metadata around it.
Multiply by a nightly snapshot that pins each version and `.DS_Store` alone can
put hundreds of megabytes into `usedbysnapshots` over a year, on the dataset with
the deepest retention in the pool.

There is no supported switch to stop `.DS_Store` on a locally-attached volume —
`DSDONTWRITENETWORKSTORES` only covers network shares. So the mitigation is
behavioural: **browse the library in Jellyfin, not in Finder.** Jellyfin itself
is clean, which is the whole point of this test.

Worth watching the noise count rather than ignoring it entirely: a large or
growing Spotlight footprint on the media datasets is its own problem, since
Spotlight indexing a multi-terabyte library competes for the same USB bus as
playback, and `mdutil -i off /Volumes/tank` is the fix if it becomes one.

## The snapshots

Named `test-jfro-<timestamp>`, never `auto-`. The production pruner in
`tank-snapshot.sh` anchors on the `auto-` prefix, so it cannot destroy these,
and `clean` checks the prefix before destroying anything so a truncated state
file cannot become `zfs destroy tank/media@`. The two namespaces provably cannot
collide in either direction — the same discipline as
`tests/snapshot-retention/`.

`clean` is deliberately not automatic on failure. A failed run's snapshots *are*
the evidence: they still hold the pre-scan state, so `zfs diff` can be re-run
against them as settings are changed.

## Also worth checking after a scan: that transcoding is actually on hardware

Not part of this test, because it needs playback rather than a scan, but it is
the other thing that fails silently. The whole native-over-Docker decision was
made for the media engine, and Jellyfin falls back to software encoding without
erroring — a software transcode and a hardware transcode look identical from the
client, except that one of them is eating the CPU that comfyui and the local LLM
stack are using.

Play something that forces a transcode (change the quality selector to a lower
bitrate), then:

```sh
grep -i videotoolbox /var/log/jellyfin/log_*.log | tail -5
```

The ffmpeg command line Jellyfin logs should contain `-hwaccel videotoolbox` and
an encoder of `h264_videotoolbox`. Seeing `libx264` there means it fell back to
software, and the settings page will still say hardware acceleration is on.
