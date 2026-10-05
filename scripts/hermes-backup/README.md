# hermes-backup — the Hermes agents' personalities, onto tank and off-site

Every night at 01:00, `hermes-backup.sh` copies the parts of each Hermes agent
that make up the agent: `SOUL.md`, `memories/`, `skills/`, `state.db`
(conversation history), `sessions/`, `config.yaml`, `.env`, plus the small
cron, kanban, project, plan and platform state. The code checkout, bundled
node and caches are left out because they can be reinstalled. `MANIFEST` in
each copy lists what was left out and records the `hermes-agent` commit.

Every profile is its own agent, and the copies mirror `~/.hermes`:

| Agent | Source | Copy |
|---|---|---|
| default (Xochiquetzal) | `~/.hermes` | `/Volumes/tank/documents/hermes/current/` |
| any profile, e.g. `tezcatlipoca` | `~/.hermes/profiles/<name>` | `/Volumes/tank/documents/hermes/profiles/<name>/current/` |

Profiles are found automatically, so a new one is backed up from its first
night. Each agent is backed up on its own: one that refuses or fails doesn't
stop the others, and the alert lists every agent with a problem. A profile's
`workspace/` (files the agent made) and `auth.json` (its provider login, which
rotates) are not copied.

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
cat /Volumes/tank/documents/hermes/profiles/*/current/MANIFEST
```

Failures and refusals go to the zed Discord channel, like the other daemons.

## When it refuses (exit 1)

- **`tank/documents` not mounted**: the pool isn't up. Fix that first. Tomorrow's
  run catches up.
- **No SOUL.md, memories/ or state.db**: that agent looks blank. Its last good
  copy is left alone on purpose. A profile that has never been used and was
  never copied is skipped quietly instead.
- **state.db shrank below 50%**: the same protection, for a reset agent that
  still has its files. If you pruned history on purpose, run
  `sudo /usr/local/sbin/hermes-backup.sh --force` once.

A deleted profile's last copy stays under `profiles/<name>/`; the log notes it
every night. Delete that folder by hand once you're sure.

## Restore

1. Reinstall Hermes, then `git -C ~/.hermes/hermes-agent checkout <commit from MANIFEST>`
   so the database schema matches.
2. Quit Hermes (desktop app and every gateway).
3. Copy each agent back to its source and remove `MANIFEST`:
   - default: `cp -Rp /Volumes/tank/documents/hermes/current/. ~/.hermes/`
   - a profile: `hermes profile create <name>`, then
     `cp -Rp /Volumes/tank/documents/hermes/profiles/<name>/current/. ~/.hermes/profiles/<name>/`
4. Start Hermes. Log a profile back in to its provider if it used one
   (`<name> auth add ...`).

Older versions: `/Volumes/tank/documents/.zfs/snapshot/*/hermes/current` (7
daily, 4 weekly, 6 monthly), or `restic restore latest --tag documents --include
/Volumes/tank/documents/hermes --target /tmp/restore` from the off-site
repository. Thaw it first; see `../nas-offsite/README.md`.
