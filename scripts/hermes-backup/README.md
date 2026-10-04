# hermes-backup — the Hermes agent's personality, onto tank and off-site

Every night at 01:00, `hermes-backup.sh` copies the parts of `~/.hermes` that
make up the agent into `/Volumes/tank/documents/hermes/current/` (about 20 MB):
`SOUL.md`, `memories/`, `skills/`, `state.db` (conversation history),
`sessions/`, `config.yaml`, `.env`, plus the small cron, kanban, project and
platform state. The code checkout, bundled node and caches are left out because
they can be reinstalled. `MANIFEST` in the copy lists what was left out and
records the `hermes-agent` commit.

A night with no changes writes nothing. Unchanged files are hard-linked to the
previous copy, so the daily `documents` snapshots only pay for what changed.

Off-site comes for free: `documents` is already a whole-dataset target of
`local.tank-offsite`, so it goes with the rest. No extra line in
`/etc/tank-offsite/targets` is needed.

## Install

```sh
cd ~/repos/nas/scripts
sudo install -m 755 -o root -g wheel hermes-backup/hermes-backup.sh /usr/local/sbin/
sudo install -m 644 -o root -g wheel hermes-backup/local.hermes-backup.plist /Library/LaunchDaemons/
sudo install -m 644 -o root -g wheel nas-scrub/tank.newsyslog.conf /etc/newsyslog.d/tank.conf
sudo launchctl bootstrap system /Library/LaunchDaemons/local.hermes-backup.plist
sudo launchctl kickstart -k system/local.hermes-backup     # first run, now
cat /var/log/hermes-backup.last                            # expect: exit 0 ok
```

## Check on it

```sh
cat /var/log/hermes-backup.last
tail -20 /var/log/hermes-backup.log
cat /Volumes/tank/documents/hermes/current/MANIFEST
```

Failures and refusals go to the zed Discord channel, like the other daemons.

## When it refuses (exit 1)

- **`tank/documents` not mounted**: the pool isn't up. Fix that first. Tomorrow's
  run catches up.
- **No SOUL.md, memories/ or state.db**: `~/.hermes` looks blank. The last good
  copy is left alone on purpose.
- **state.db shrank below 50%**: the same protection, for a reset agent that
  still has its files. If you pruned history on purpose, run
  `sudo /usr/local/sbin/hermes-backup.sh --force` once.

## Restore

1. Reinstall Hermes, then `git -C ~/.hermes/hermes-agent checkout <commit from MANIFEST>`
   so the database schema matches.
2. Quit Hermes (desktop app and gateway).
3. `cp -Rp /Volumes/tank/documents/hermes/current/. ~/.hermes/` and remove `MANIFEST`.
4. Start Hermes.

Older versions: `/Volumes/tank/documents/.zfs/snapshot/*/hermes/current` (7
daily, 4 weekly, 6 monthly), or `restic restore latest --tag documents --include
/Volumes/tank/documents/hermes --target /tmp/restore` from the off-site
repository. Thaw it first; see `../nas-offsite/README.md`.
