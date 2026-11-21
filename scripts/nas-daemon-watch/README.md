# Noticing that a service is dead — `local.daemon-watch`

Checks the machine's always-on services every 5 minutes and says so in the
[zed Discord channel](../nas-scrub/zed.rc.local) when one stops answering.

It exists because of a 29-hour outage nobody noticed. On 2026-11-20 the macOS
27.2.1 update swept `/var/log`, and all three non-root daemons here —
`local.jellyfin`, `local.copyparty` and `com.local.llmster` — failed to spawn
with `EX_CONFIG` (78) at `15:56:28`, because launchd opens `StandardOutPath` as
the job's user before `exec` and could not recreate a file in a root-owned
`/var/log`. Nothing was logged, because the thing that failed was the opening of
the log. `KeepAlive` retried in silence ~3500 times each. Jellyfin and copyparty
were found ~28 h later by someone trying to watch something; LM Studio was
missed in that pass and reached 29 h, with every agent, Open WebUI, Hindsight,
Codex and the public endpoint dead.

That logging bug is fixed — see [[nas_log]], *Logs out of /var/log entirely
(2026-11-21)*. This daemon is the other half: the reason it lasted a day is that
nothing watched.

## What it checks

| Service | Label | Probe | Must contain |
| --- | --- | --- | --- |
| Jellyfin | `local.jellyfin` | `127.0.0.1:8096/health` | `Healthy` |
| copyparty | `local.copyparty` | `127.0.0.1:3923/` | any 2xx |
| LM Studio | `com.local.llmster` | `127.0.0.1:1234/api/v0/models` | the alias, `loaded`, 262144 |

The list is a table at the top of
[daemon-watch.sh](daemon-watch.sh) — `domain|label|name|url|substrings`. Adding
a service is one line; nothing else in the script knows about the list.

**The probe is the verdict, launchd is the explanation.** "Is the port
answering" is what a user experiences, and it catches failures launchd is
perfectly happy about: on 2026-11-09 llmster's model worker died while llmster
stayed up, so `launchctl print` read healthy for 2.5 h while every client got
"No models loaded". `launchctl print` and the unified log are read only to put a
reason in the alert — `job state = spawn failed`, `last exit code = 78`, and
launchd's own message, which for the outage above is the single line that
explains everything.

**The three LM Studio substrings are each a past failure.** The alias `id` is
what clients ask for and what a JIT load cannot create; `"state":"loaded"` is
the dead-worker case above; `"loaded_context_length":262144` is the JIT reload
that comes back at 8192 and breaks OpenClaw with *tokens to keep … greater than
the context length*. `/api/v0/models`, not `/v1/models` — only the former
reports load state, and `/v1/models` lists everything downloaded, so it would
have answered `200` through every one of those failures.

**Not watched:** the periodic root daemons (`tank-scrub`, `tank-snapshot`,
`tank-offsite`, `hermes-backup`). They report their own verdicts to the same
channel, and "is it running" is the wrong question for a job that is supposed to
be absent most of the time. Their real gap is a *missed schedule*, which is a
different check and is not built — see [[nas_log#Open questions and known weak
points]]. Whisper (`com.local.whisper-server`, a user LaunchAgent on `:8901`) is
a candidate and is one line away.

## How it behaves

- **Two consecutive failures before it alerts.** Jellyfin takes ~15 s to start,
  llmster ~25 s to load 22 GiB, and llmster's own watchdog reloads the model on
  purpose now and then. One missed probe during any of that is normal; two in a
  row, 5 minutes apart, is not. The cost is up to ~10 minutes of silence before
  the first alert, against the 29 h it replaces.
- **One alert per outage, and one line when it comes back.** A message every 5
  minutes for a day trains you to ignore the channel. State is one small file
  per service in `/usr/local/var/daemon-watch/`.
- **A heartbeat every 7 days** listing what is up. A channel that only ever
  speaks on failure is indistinguishable from a broken channel — same reasoning
  as `tank-snapshot`'s monthly summary. If the heartbeat stops arriving, the
  watchman is what is broken.
- **It cannot be killed by its own logging.** The plist names no
  `StandardOutPath`; the script creates `/usr/local/var/log/daemon-watch`
  itself and guards its redirect, so it starts whether or not it can log. A
  watchman that dies of a missing log file is worse than none, because its
  silence reads as good news.
- **It changes nothing.** No restarts, no `kickstart`, no repair. Deliberate:
  the failures seen so far were not things a restart fixes, and a watchdog that
  acts can mask a fault for weeks. It probes, decides, notifies.

## The bug this daemon hit on its own first install

Worth keeping, because it widens the lesson. The first version of the plist
carried `WorkingDirectory /usr/local/var/daemon-watch` — a directory the script
creates on its first run. launchd `chdir`s *before* `exec`, so:

```
launchctl print system/local.daemon-watch
#   state = not running
#   runs = 1
#   last exit code = 78: EX_CONFIG

log show --predicate 'eventMessage CONTAINS "daemon-watch"' --last 5m
# Unable to set current working directory.
# path = /usr/local/var/daemon-watch, error 0x2 - No such file or directory
```

Same exit code, same silence, same shape as the outage this daemon exists to
notice — in the daemon written to notice it, found 90 seconds after installing
it. So the rule is not "don't name a log file in a plist". It is:

> **Every filesystem path in a plist is a path launchd touches before your code
> runs, and anything it cannot do there is a spawn failure that cannot explain
> itself.**

`StandardOutPath`, `StandardErrorPath` and `WorkingDirectory` are all that kind
of path. This plist now names none of them.

## Files

| File | Installed to |
| --- | --- |
| [daemon-watch.sh](daemon-watch.sh) | `/usr/local/sbin/daemon-watch.sh` |
| [local.daemon-watch.plist](local.daemon-watch.plist) | `/Library/LaunchDaemons/local.daemon-watch.plist` |
| [daemon-watch.newsyslog.conf](daemon-watch.newsyslog.conf) | `/etc/newsyslog.d/daemon-watch.conf` |

Thresholds, the probe timeout and the heartbeat interval are variables at the
top of the script, each overridable by an environment variable for testing.

## Install

```sh
cd ~/repos/nas/scripts/nas-daemon-watch
sudo install -o root -g wheel -m 755 daemon-watch.sh /usr/local/sbin/daemon-watch.sh
sudo install -o root -g wheel -m 644 local.daemon-watch.plist /Library/LaunchDaemons/local.daemon-watch.plist
sudo install -o root -g wheel -m 644 daemon-watch.newsyslog.conf /etc/newsyslog.d/daemon-watch.conf
sudo launchctl bootstrap system /Library/LaunchDaemons/local.daemon-watch.plist
```

## Operating it

```sh
sudo launchctl print system/local.daemon-watch | grep -E 'state|runs|last exit'
tail -20 /usr/local/var/log/daemon-watch/watch.log
cat /usr/local/var/daemon-watch/local.jellyfin     # "<consecutive failures> <alerted?>"

# Run a check right now
sudo launchctl kickstart -k system/local.daemon-watch

# Force the next heartbeat
sudo rm /usr/local/var/daemon-watch/heartbeat
```

**Test it without touching the real services or the channel.** Every path —
first failure, alert, no second alert, recovery, heartbeat — is reachable with
environment overrides and a copy of the script pointed at a dead port:

```sh
d=$(mktemp -d)
sed 's|http://127.0.0.1:8096/health|http://127.0.0.1:9|' daemon-watch.sh >"$d/broken.sh"
export DAEMON_WATCH_DRY_RUN=1 DAEMON_WATCH_LOGDIR="$d/log" DAEMON_WATCH_STATE="$d/state"
sh "$d/broken.sh"        # DOWN 1/2, no alert
sh "$d/broken.sh"        # DOWN 2/2, alert
sh "$d/broken.sh"        # still down, no second alert
sh ./daemon-watch.sh     # RECOVERED, then heartbeat
cat "$d/log/watch.log"
```

`DAEMON_WATCH_DRY_RUN=1` logs the notification instead of posting it, so this
never touches Discord.

## Standing checks

- **Confirm an alert actually arrives, once a quarter.** Same reasoning as the
  rest of the channel: delivery can fail silently in both directions. The cheap
  version is `sudo rm /usr/local/var/daemon-watch/heartbeat` followed by a
  `kickstart`, which posts the heartbeat for real.
- **This daemon does not watch itself.** The heartbeat is the only evidence it
  is alive, so noticing that the heartbeat stopped is a human job. There is no
  second watchman and there probably should not be.
