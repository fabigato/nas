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
| Lifecycle | noncurrent versions expire at 180 days; incomplete uploads aborted after 7 days. **No storage-class transition** — see below |
| Storage class | set by restic at upload (`-o s3.storage-class=DEEP_ARCHIVE`): content packs go straight to Deep Archive; tree packs, index, snapshots, keys and config stay in Standard |
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

### When did it last run, and when will it run next

Nightly at 01:30. Each target uploads when its last successful run is older
than its interval; a new target has no state file, so it goes on the next run.

```sh
cat /var/log/tank-offsite.last          # one-line summary of the last run
ls -l /var/lib/tank-offsite/            # <target>.last per target, / becomes _
tail -50 /var/log/tank-offsite.log      # the full story
```

- A syntax error in `targets` refuses the whole run, not just the new line.
- A scrub or resilver in progress defers the run to the next night.

### Why restic picks the storage class, not a lifecycle rule

restic keeps two kinds of pack under `data/`: **content** (file bytes) and
**trees** (each snapshot's directory structure). Trees are read by `check`,
`prune`, `ls`, `find`, by `backup` to skip unchanged files, and by every
restore. Content is read only by a restore.

The first design moved all of `data/` to Deep Archive after 7 days. On
2026-10-10, the first night the seed's trees had gone cold, `restic check`
failed on every snapshot with *"The operation is not valid for the object's
storage class"*. S3 cannot tell a tree pack from a content pack, so no
lifecycle filter can fix that. restic can: with an archive class it applies the
class to content packs only (`useStorageClass` in restic's `s3.go`, checked
against 0.19.1).

The price was the old read-back check, which restored a few just-uploaded files
for free while their packs were still warm. Content is now cold from the moment
it lands, so that proof comes from the quarterly restore test instead.

### When the storage-class check alerts

Every run lists `data/`, reads restic's index to learn which packs are trees,
and alerts if any tree pack is out of Standard. Content left in Standard is
only logged: it costs money, it breaks nothing.

```sh
pass show nas/offsite-prune-aws | sudo /usr/local/sbin/tank-offsite.sh --fix-classes --dry-run
pass show nas/offsite-prune-aws | sudo /usr/local/sbin/tank-offsite.sh --fix-classes
```

It requests a Standard-tier thaw for each cold tree pack and copies warm content
packs to Deep Archive. It exits **3** while thaws are pending — run it again in
~12 h and it copies the thawed trees back to Standard, then exits 0. It needs the
prune credential, because the backup credential cannot issue a Glacier restore,
and it refuses to move anything if it cannot read restic's whole index, because
without it a tree pack looks like content.

Each copy leaves the replaced object as a noncurrent version for 180 days, so a
mistake is recoverable, and that copy is billed until then.

### Restore, and verify

```sh
sudo -i
set -a; . /etc/tank-offsite/env; . /etc/tank-offsite/backup.env; set +a
export RESTIC_PASSWORD_FILE=/etc/tank-offsite/repo.pass
export RESTIC_CACHE_DIR=/var/cache/tank-offsite

restic snapshots                                            # what is there
# content is in Deep Archive: thaw what the restore will read first (see below)
restic restore latest --tag documents --target /tmp/restoretest
diff -r /tmp/restoretest/Volumes/tank/documents /Volumes/tank/documents
restic check --read-data-subset=2%                          # re-verify real packs
restic unlock                                               # if "already locked"
```

`diff` listing the excluded cruft as present only in the source is correct, not
a discrepancy.

**Restoring or `--read-data-subset` needs a Glacier thaw first.** Content packs
are in Deep Archive from the moment they are uploaded, so the quarterly restore
test is a two-phase job: thaw what it will read, wait ~12 h, then restore. It is
the one check that proves the *stored bytes* are the bytes you sent, rather than
that the bookkeeping is self-consistent.

Plain `restic check`, without `--read-data`, runs after every backup. It reads
the index, the snapshots and every tree pack, all of which stay in Standard, and
never touches content.

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

**A few files need only their own packs thawed — in principle.** The trees are in
Standard, so `restic snapshots`, `ls` and `find` work with nothing thawed, and
restic knows which content packs a file needs. restic's experimental
`s3-restore` feature (`RESTIC_FEATURES=s3-restore restic restore -o
s3.enable-restore=1 ...`) issues those thaws itself. **UNREHEARSED** — until it
has been run once, budget a full restore as thawing all of `data/`.

### Drop a snapshot you know is junk

```sh
sudo -v                                 # get sudo's password prompt out of the way
pass show nas/offsite-prune-aws | sudo /usr/local/sbin/tank-offsite.sh --drop <snapshot-id>
```

It needs the **prune credential** piped in: the backup credential on this
machine cannot delete anything but locks, by design (see the threat model). The
key is read from the pipe and never written to disk. It shows only the snapshot
being dropped, asks you to type its id at the terminal, then forgets it and
deletes whatever data no remaining snapshot uses.

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
