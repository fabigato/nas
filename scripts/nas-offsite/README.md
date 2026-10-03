# nas-offsite — the third copy, in S3 Glacier Deep Archive

`tank` is copy 1. `tankbak` is copy 2, offline and in the same building. This is
copy 3: encrypted, off-site, and the only one that survives the room.

## What you do by hand, before anything else

Everything below is console work that cannot be scripted, because it is the
bootstrap credential the scripts need in order to exist.

### 1. Secure the root account

AWS root can do anything, including deleting the backup and closing the account.
It should be used once — now — and then never again.

- Sign in as root.
- **IAM → enable MFA on the root user.** Authenticator app is fine.
- Do **not** create root access keys. If any exist, delete them.

### 2. Create a bootstrap admin user

- **IAM → Users → Create user**, name `macstudio-admin` (the script defaults to this; override with `OFFSITE_USER_ADMIN` if you named it something else).
- Tick *Provide user access to the AWS Management Console* if you want to click
  around later; not required for the scripts.
- **Permissions → Attach policies directly → `AdministratorAccess`.**
- Create the user, then open it → **Security credentials → Create access key**
  → *Command Line Interface (CLI)*.
- Copy both the **Access key ID** and the **Secret access key**. The secret is
  shown exactly once.

This is a temporary key. `bootstrap-offsite.sh` uses it to create the bucket and
the two scoped users, after which it should be deleted — the script reminds you.

### 3. Put the key somewhere the script can read it

```sh
pass insert -m nas/offsite-bootstrap-aws     # paste both lines, then Ctrl-D
```

Format the entry as two lines so the script can read it directly:

```
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
```

### 4. Install the tooling

```sh
brew install restic awscli
```

`restic` is the backup program. `awscli` is only used by the bootstrap and by
the restore test; the backup job itself talks to S3 directly through restic.

## Then

```sh
sh bootstrap-offsite.sh --dry-run    # print every AWS call it would make
sh bootstrap-offsite.sh              # create everything, stage the config
```

It runs **unprivileged on purpose** — it never writes to `/etc` itself. It
stages the three config files under `./staged/` with mode 0600 and prints a
`sudo install` block for you to review and run, same as every other script here.

## What gets created

| | |
|---|---|
| Bucket | `tank-offsite-<random>` in `eu-central-1` (Frankfurt) |
| Versioning | on — a delete leaves a recoverable previous version |
| Public access | blocked, all four settings |
| Lifecycle | `data/` → Deep Archive after 7 days; noncurrent versions expire at 180 days; incomplete uploads aborted after 7 days |
| IAM user 1 | `tank-offsite-backup` — append-only. Can write and read, can only delete inside `locks/`. Its key lives on the Mac. |
| IAM user 2 | `tank-offsite-prune` — can delete objects, but **not** object *versions*. Its key lives only in `pass`. |
| restic repo | initialised at the bucket root, repository format 2 |

## Operating it, once it exists

Everything above is a one-time bootstrap. These are the things you actually do.

### Add a folder to the backup

```sh
sudo vi /etc/tank-offsite/targets        # <path relative to /Volumes/tank>  <days>
sudo launchctl kickstart -k system/local.tank-offsite
```

Targets are **paths, not datasets**, so a chosen folder inside an otherwise
excluded dataset can be included — `media/concerts 30`. That is the whole point:
`media` as a bulk is re-downloadable and has no offsite priority, but individual
folders in it can still matter.

Relative paths only, no `..`. A new target has no state file, so it uploads on
the next run. A **syntax** error refuses the whole run, because a table that does
not parse cannot be trusted. A path that **does not exist** takes out only its own
target and alerts — refusing everything would mean one renamed folder stops every
offsite backup, and you get the alert either way.

### Exclude something

```sh
sudo vi /etc/tank-offsite/exclude        # one restic pattern per line
```

macOS cruft is already excluded inside the script and should not be repeated
here: `.DS_Store`, `.Spotlight-V100`, `.fseventsd`, `.Trashes`,
`.TemporaryItems`, `.DocumentRevisions-V100`. That list is a fact about the
platform; this file is your opinion.

Takes effect on the next run. Copies already archived stay in the snapshots that
reference them until those age out — excluding something does not reach backwards.

### Restore, and verify

```sh
sudo -i
set -a; . /etc/tank-offsite/env; . /etc/tank-offsite/backup.env; set +a
export RESTIC_PASSWORD_FILE=/etc/tank-offsite/repo.pass
export RESTIC_CACHE_DIR=/var/cache/tank-offsite

restic snapshots                                            # what is there
restic restore latest --tag documents --target /tmp/restoretest
diff -r /tmp/restoretest/Volumes/tank/documents /Volumes/tank/documents
restic check --read-data-subset=2%                          # re-verify real packs
restic unlock                                               # if "already locked"
```

`diff` listing the excluded cruft as present only in the source is correct, not
a discrepancy.

**`--read-data-subset` is only cheap while the packs are still in Standard — the
first 7 days after upload.** It is the one check that proves the *stored bytes*
are the bytes you sent, rather than that the bookkeeping is self-consistent.
After the lifecycle transition it needs a Glacier restore first and a 12-hour
wait, which is why the quarterly restore test has to be a two-phase job.

Plain `restic check`, without `--read-data`, is metadata-only and runs after
every backup. It works fine against Deep Archive because it never touches
`data/`.

### Restore when the Mac is gone — the actual disaster

The recipe above assumes a working machine with `/etc/tank-offsite` on it. This
one assumes none of that, which is the case copy 3 exists for.

> **UNREHEARSED.** Every step below is reasoned, not measured — `tests/offsite-restore/`
> does not exist yet. The 2026-10-03 verification restored from **Standard**,
> which proves the repository is readable and says nothing about the Glacier
> path. Treat this as a draft until it has been run once for real.

**What you need, none of which is on the dead machine:** the repository password
(`pass nas/offsite-repo`), the bucket name and region (same place), and an AWS
credential (`pass nas/offsite-prune-aws`, which can read and issue restores).

**1. Wake the data up. This is the step people forget.** restic cannot read a
Deep Archive object at all — not slowly, *at all*. Every object under `data/`
must be restored to a readable tier first, and that takes 12 h (Standard) or
48 h (Bulk, cheaper). Nothing in restic triggers this; it is an S3 operation.

```sh
B=tank-offsite-xxxxxxxx
aws s3api list-objects-v2 --bucket "$B" --prefix data/ \
  --query 'Contents[?StorageClass==`DEEP_ARCHIVE`].Key' --output text \
  | tr '\t' '\n' >/tmp/cold.txt
wc -l /tmp/cold.txt                     # ~8000 objects at 64 MiB packs

while read -r k; do
  aws s3api restore-object --bucket "$B" --key "$k" \
    --restore-request 'Days=14,GlacierJobParameters={Tier=Bulk}'
done </tmp/cold.txt
```

`Days=14` because the restored copies are temporary and 491 GiB takes ~15 h to
pull down at 85 Mbit — do not set it to 1 and watch them expire mid-download.
For this object count a loop is fine; S3 Batch Operations is the tool if the
repository ever grows an order of magnitude.

**2. Wait, then confirm.** `ongoing-request="false"` means that object is ready.

```sh
aws s3api head-object --bucket "$B" --key "$(head -1 /tmp/cold.txt)" --query Restore
```

**3. Then restic, with everything set by hand.**

```sh
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
export RESTIC_REPOSITORY=s3:s3.eu-central-1.amazonaws.com/$B
export RESTIC_PASSWORD=...              # from pass nas/offsite-repo
restic snapshots
restic restore <id> --target /recovered
```

**Budget, at 491 GiB:** ~$1.25 Bulk retrieval, ~$44 egress after the free 100 GB,
and about two days wall-clock — 48 h of thaw plus 15 h of download. The money is
not the problem; assuming it is a two-hour job is.

**You cannot cheaply restore just a few files.** Which packs hold a given file is
not something you can read off the outside of the bucket, so budget for thawing
all of `data/`. This is the main thing Deep Archive costs you, and it is the
right trade for a copy you hope never to read.

### Drop a snapshot you know is junk

```sh
sudo /usr/local/sbin/tank-offsite.sh --drop <snapshot-id>
```

Lists what is there, asks you to retype the id, then forgets it and reclaims the
space. Note that Deep Archive bills a 180-day minimum per object, so deleting
anything sooner than that frees no money — only space you were going to stop
paying for anyway.

## The three things that must survive this machine

The whole point of copy 3 is the Mac being destroyed or stolen. If any of these
exists only here, the backup is unreadable in exactly the case it was built for.

1. **The restic repository password** — `pass` at `nas/offsite-repo`, **and on
   paper**, with the `tankbak` passphrase.
2. **The bucket name and region** — useless secret, essential fact. Same places.
3. **The prune credential** — `pass` at `nas/offsite-prune-aws`. Without it you
   can still restore (the backup credential can read), but you cannot clean up.

A lost repository password is unrecoverable. There is no reset.

## Threat model, stated honestly

The backup credential and the repository password both sit on the Mac's
internal SSD, which is not FileVault-encrypted — the same exposure `tank.key`
already has, and accepted for the same reason: the job has to run unattended.

So an attacker with the Mac **can read the archive**. That is a confidentiality
loss, and it is real.

What they cannot do is **destroy** it. The backup credential has no
`s3:DeleteObject` outside `locks/`, the prune credential is not on the machine,
and bucket versioning means even a successful delete leaves the previous version
recoverable for 180 days. Ransomware that encrypts `tank`, wipes the ZFS
snapshots and then runs the backup job cannot take copy 3 with it.
