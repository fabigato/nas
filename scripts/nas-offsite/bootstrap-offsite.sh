#!/bin/sh
#
# bootstrap-offsite.sh — create the S3 bucket, lifecycle rules, IAM users and
# restic repository that copy 3 lives in. Run once.
#
# WHAT THIS IS FOR
# `tank` is copy 1. `tankbak` is copy 2 — offline, but in the same building, so
# it dies with the room. This creates the place copy 3 lives: an encrypted
# restic repository in S3 Glacier Deep Archive, in Frankfurt.
#
# --- DESIGN ---------------------------------------------------------------
#
# 1. IT RUNS UNPRIVILEGED AND WRITES NOTHING TO /etc.
#
# It needs an AWS admin key. Under `sudo` that key would have to arrive through
# the environment or the command line, which puts a credential with full account
# access into the process table and the shell history. So this stays a normal
# user process, reads the key from `pass`, and STAGES the three config files
# into ./staged/ at mode 0600. Installing them is a separate reviewed step —
# the same staged-review pattern as every other script here.
#
# 2. TWO IAM USERS, AND THE SPLIT IS THE WHOLE SECURITY MODEL.
#
# The Mac is not FileVault-encrypted and `tank.key` already sits on its SSD, so
# assume an attacker with the machine reads whatever the backup job can read.
# That is accepted for confidentiality. It is NOT accepted for destruction.
#
#   tank-offsite-backup   can PutObject and GetObject anywhere in the bucket,
#                         and DeleteObject ONLY under locks/. Its key lives in
#                         /etc/tank-offsite/backup.env because the nightly job
#                         is unattended and has no other way to get one.
#
#   tank-offsite-prune    can DeleteObject, and is the only thing that can.
#                         Its key NEVER touches this machine's disk — it lives
#                         in `pass` and is read at the moment prune runs.
#
# Neither can delete object VERSIONS, and neither can touch the bucket's own
# configuration. So the worst a compromised Mac can do is write garbage and
# read the archive. It cannot remove it. Reclaiming space is the job of the
# lifecycle rule, which no credential here can edit.
#
# 3. THE LIFECYCLE RULE IS SCOPED TO data/ AND THAT IS LOAD-BEARING.
#
# restic must read its own bookkeeping — config, keys/, index/, snapshots/,
# locks/ — on EVERY run. Those are a few hundred KB. If a blanket rule pushed
# them into Deep Archive, restic could not start at all, and the failure would
# arrive weeks later when the transition finally fired, not today when it would
# be obvious. So only data/ transitions. Everything else stays in Standard,
# costs cents a year, and keeps the repository openable.
#
# The 7-day delay before transition is deliberate: for a week after each run the
# newly written packs are still readable at Standard rates, which is what makes
# the monthly read-back check free and instant instead of a 12-hour Glacier
# round trip.
#
# 4. THE ABORT-INCOMPLETE-UPLOADS RULE IS NOT BOILERPLATE.
#
# restic writes 64 MiB packs, which S3 takes as multipart uploads. An
# interrupted run — and the initial seed is ~54 hours at 29 Mbit/s, so plan on
# at least one — leaves orphaned parts behind. Those parts BILL, and they do not
# appear in any object listing, so the only symptom is a storage line that does
# not match what you can see. The rule sweeps them after 7 days.
#
# 5. THE REPOSITORY IS INITIALISED WITH THE *BACKUP* CREDENTIAL, ON PURPOSE.
#
# It would be easier to init with the admin key. Using the restricted one
# instead makes `restic init` a live test of the append-only policy: if the
# policy is missing a permission restic actually needs, we find out here, in a
# step that can be re-run, rather than at 04:00 in three weeks.
#
# --- USAGE ---------------------------------------------------------------
#
# Prerequisites are in README.md — root MFA, an admin key in `pass` at
# nas/offsite-bootstrap-aws, and `brew install restic awscli`.
#
#   sh bootstrap-offsite.sh --dry-run   # print every mutating call, do nothing
#   sh bootstrap-offsite.sh             # create everything, stage the config
#   sh bootstrap-offsite.sh --no-verify # skip the policy probes (not advised)
#
# Safe to re-run. Every step checks for its own result first, so a run that
# died halfway can simply be repeated.
#
# Exit codes:
#   0  everything created and staged
#   1  refused to start (missing tool, missing credential, bad account)
#   2  an AWS or restic operation failed — READ THE OUTPUT
#   3  a policy probe came back wrong — the IAM split is NOT doing what it says

set -u

REGION=${OFFSITE_REGION:-eu-central-1}
USER_BACKUP=${OFFSITE_USER_BACKUP:-tank-offsite-backup}
USER_PRUNE=${OFFSITE_USER_PRUNE:-tank-offsite-prune}
# The bootstrap admin user you created in the console. Only referenced in the
# revoke instructions at the end — nothing here depends on its name.
USER_ADMIN=${OFFSITE_USER_ADMIN:-macstudio-admin}
PASS_BOOTSTRAP=${OFFSITE_PASS_BOOTSTRAP:-nas/offsite-bootstrap-aws}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STAGE=${OFFSITE_STAGE:-$SCRIPT_DIR/staged}

DRY_RUN=0
VERIFY=1
for arg in "$@"; do
	case "$arg" in
	--dry-run) DRY_RUN=1 ;;
	--no-verify) VERIFY=0 ;;
	*)
		echo "unknown argument: $arg" >&2
		exit 1
		;;
	esac
done

say() { echo "$*"; }
step() { echo; echo "== $*"; }
die() {
	echo "REFUSED: $*" >&2
	exit "${2:-1}"
}

# Print a mutating command and run it, or print it and don't. Read-only probes
# call the aws CLI directly instead — a dry run still has to be able to see what
# already exists, or it cannot tell you what it would change.
run() {
	if [ "$DRY_RUN" = 1 ]; then
		echo "  [dry-run] $*"
		return 0
	fi
	echo "  \$ $*"
	"$@"
}

# ---------------------------------------------------------------- preflight

step "Preflight"

for t in aws restic curl openssl; do
	command -v "$t" >/dev/null 2>&1 ||
		die "$t is not installed. brew install restic awscli"
done
say "  tooling: $(restic version 2>/dev/null | head -1), $(aws --version 2>&1 | head -1)"

# Read the bootstrap key out of `pass` rather than the environment, so it never
# lands in shell history and is never exported to a child that does not need it.
command -v pass >/dev/null 2>&1 || die "pass is not installed"
BOOT_BLOB=$(pass show "$PASS_BOOTSTRAP" 2>/dev/null) ||
	die "no credential at pass:$PASS_BOOTSTRAP — see README.md step 3"

AWS_ACCESS_KEY_ID=$(printf '%s\n' "$BOOT_BLOB" |
	awk -F= '/^AWS_ACCESS_KEY_ID=/ { print $2; exit }')
AWS_SECRET_ACCESS_KEY=$(printf '%s\n' "$BOOT_BLOB" |
	awk -F= '/^AWS_SECRET_ACCESS_KEY=/ { print $2; exit }')
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] ||
	die "pass:$PASS_BOOTSTRAP must hold AWS_ACCESS_KEY_ID= and AWS_SECRET_ACCESS_KEY= lines"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN 2>/dev/null || true

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) ||
	die "the bootstrap credential does not work — check pass:$PASS_BOOTSTRAP"
CALLER=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
say "  account: $ACCOUNT"
say "  caller:  $CALLER"

case "$CALLER" in
*":root") die "that is the ROOT key. Delete it and use an IAM admin user — README.md step 2" ;;
esac

mkdir -p "$STAGE" || die "cannot create $STAGE"
chmod 700 "$STAGE"

# ------------------------------------------------------------------- bucket

step "Bucket"

# Reuse the name from a previous run if there was one. S3 bucket names are
# global across every AWS account on earth, so a fresh random suffix on a re-run
# would silently create a SECOND bucket and leave the first one billing.
if [ -f "$STAGE/env" ]; then
	BUCKET=$(awk -F= '/^OFFSITE_BUCKET=/ { print $2; exit }' "$STAGE/env")
	say "  reusing staged bucket name: $BUCKET"
else
	BUCKET=${OFFSITE_BUCKET:-tank-offsite-$(openssl rand -hex 6)}
	say "  new bucket name: $BUCKET"
fi

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
	say "  already exists — skipping create"
else
	run aws s3api create-bucket \
		--bucket "$BUCKET" \
		--region "$REGION" \
		--create-bucket-configuration "LocationConstraint=$REGION" ||
		die "create-bucket failed" 2
fi

step "Bucket settings"

run aws s3api put-public-access-block \
	--bucket "$BUCKET" \
	--public-access-block-configuration \
	"BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" ||
	die "put-public-access-block failed" 2

run aws s3api put-bucket-versioning \
	--bucket "$BUCKET" \
	--versioning-configuration Status=Enabled ||
	die "put-bucket-versioning failed" 2

# restic already encrypts everything before it leaves the machine, so this buys
# nothing against a thief. It is set because it is free, and because "encryption
# at rest: off" in an audit view invites someone to go fix it badly later.
run aws s3api put-bucket-encryption \
	--bucket "$BUCKET" \
	--server-side-encryption-configuration \
	'{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' ||
	die "put-bucket-encryption failed" 2

run aws s3api put-bucket-lifecycle-configuration \
	--bucket "$BUCKET" \
	--lifecycle-configuration "file://$SCRIPT_DIR/lifecycle.json" ||
	die "put-bucket-lifecycle-configuration failed" 2

say "  lifecycle rules now live:"
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
	--query 'Rules[].[ID,Status]' --output text 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------- iam users

# $1 = user name, $2 = policy template
make_user() {
	mu_user=$1
	mu_tmpl=$2

	if aws iam get-user --user-name "$mu_user" >/dev/null 2>&1; then
		say "  user $mu_user already exists"
	else
		run aws iam create-user --user-name "$mu_user" ||
			die "create-user $mu_user failed" 2
	fi

	# put-user-policy is a replace, not an append, so re-running converges
	# rather than accumulating. The policy files carry a __BUCKET__ placeholder
	# because the bucket name is not known until the line above ran.
	sed "s/__BUCKET__/$BUCKET/g" "$SCRIPT_DIR/$mu_tmpl" >"$STAGE/$mu_tmpl"
	run aws iam put-user-policy \
		--user-name "$mu_user" \
		--policy-name "${mu_user}-policy" \
		--policy-document "file://$STAGE/$mu_tmpl" ||
		die "put-user-policy $mu_user failed" 2
}

# Create an access key, but ONLY if the user has none. AWS allows two per user
# and silently hands out a second — which would leave a live credential nobody
# recorded, valid forever, for the one user that can delete things.
# $1 = user name. Prints "ID SECRET", or nothing if a key already exists.
make_key() {
	mk_user=$1
	mk_have=$(aws iam list-access-keys --user-name "$mk_user" \
		--query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null)
	if [ -n "$mk_have" ] && [ "$mk_have" != "None" ]; then
		say "  $mk_user already has an access key ($mk_have) — not creating another" >&2
		say "  if you lost its secret: aws iam delete-access-key --user-name $mk_user --access-key-id $mk_have" >&2
		return 1
	fi
	if [ "$DRY_RUN" = 1 ]; then
		echo "  [dry-run] aws iam create-access-key --user-name $mk_user" >&2
		echo "AKIADRYRUNPLACEHOLDER dryrunsecret"
		return 0
	fi
	aws iam create-access-key --user-name "$mk_user" \
		--query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text 2>/dev/null
}

step "IAM user: $USER_BACKUP (append-only, key goes on the Mac)"
make_user "$USER_BACKUP" policy-backup.json

step "IAM user: $USER_PRUNE (can delete, key goes only in pass)"
make_user "$USER_PRUNE" policy-prune.json

# ------------------------------------------------------------------- config

step "Staging config"

REPO="s3:s3.$REGION.amazonaws.com/$BUCKET"

if [ "$DRY_RUN" = 1 ]; then
	say "  [dry-run] would write $STAGE/env pinning bucket $BUCKET"
elif [ ! -f "$STAGE/env" ]; then
	cat >"$STAGE/env" <<EOF
# /etc/tank-offsite/env — staged by bootstrap-offsite.sh on $(date '+%Y-%m-%d')
# Not a secret. Knowing the bucket name grants nothing; losing it costs you the
# ability to find your own backup, so it is escrowed with the passphrase.
OFFSITE_BUCKET=$BUCKET
OFFSITE_REGION=$REGION
RESTIC_REPOSITORY=$REPO
EOF
	chmod 600 "$STAGE/env"
	say "  wrote $STAGE/env"
else
	say "  $STAGE/env exists — left alone"
fi

# The repository password. 44 characters to match the tank.key convention, from
# /dev/urandom, generated once and never regenerated: rewriting this file after
# the repo exists would lock you out of your own backup, so the guard matters
# more than it looks.
if [ ! -f "$STAGE/repo.pass" ]; then
	if [ "$DRY_RUN" = 1 ]; then
		say "  [dry-run] would generate $STAGE/repo.pass"
	else
		LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 44 >"$STAGE/repo.pass"
		chmod 600 "$STAGE/repo.pass"
		say "  wrote $STAGE/repo.pass (44 chars, never regenerated)"
	fi
else
	say "  $STAGE/repo.pass exists — left alone (regenerating it would orphan the repo)"
fi

if [ ! -f "$STAGE/backup.env" ]; then
	if BK=$(make_key "$USER_BACKUP"); then
		BK_ID=$(echo "$BK" | awk '{print $1}')
		BK_SECRET=$(echo "$BK" | awk '{print $2}')
		if [ "$DRY_RUN" = 0 ]; then
			cat >"$STAGE/backup.env" <<EOF
# /etc/tank-offsite/backup.env — the append-only credential, read by the daemon.
# This key can write and read the bucket. It CANNOT delete anything outside
# locks/. That is the only thing standing between a compromised Mac and copy 3.
AWS_ACCESS_KEY_ID=$BK_ID
AWS_SECRET_ACCESS_KEY=$BK_SECRET
EOF
			chmod 600 "$STAGE/backup.env"
			say "  wrote $STAGE/backup.env"
		fi
	else
		say "  SKIPPED backup.env — see the note above"
	fi
else
	say "  $STAGE/backup.env exists — left alone"
fi

step "Prune credential — copy this into pass now, it is shown once"

if PK=$(make_key "$USER_PRUNE"); then
	PK_ID=$(echo "$PK" | awk '{print $1}')
	PK_SECRET=$(echo "$PK" | awk '{print $2}')
	cat <<EOF

    pass insert -m nas/offsite-prune-aws

  then paste exactly these two lines and press Ctrl-D:

    AWS_ACCESS_KEY_ID=$PK_ID
    AWS_SECRET_ACCESS_KEY=$PK_SECRET

  Do NOT write this to a file on this machine. The entire reason the prune
  credential exists separately is that it is the one that can delete, and it is
  therefore the one that must not be sitting on the box being backed up.

EOF
	printf '  Press RETURN once it is in pass. '
	read -r _ack
else
	say "  $USER_PRUNE already has a key — assuming it is already in pass"
fi

# --------------------------------------------------------------- restic init

step "restic repository"

if [ "$DRY_RUN" = 1 ]; then
	say "  [dry-run] would run: restic init --repository-version 2"
else
	RESTIC_REPOSITORY=$REPO
	RESTIC_PASSWORD_FILE=$STAGE/repo.pass
	export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

	# Deliberately the restricted credential — see DESIGN 5. Bail rather than
	# fall through: with no backup.env the awk below yields empty strings, the
	# already-exported ADMIN key stays in effect, and both `restic init` and
	# every policy probe would then silently test the wrong identity. A probe
	# that passes against the wrong credential is worse than no probe.
	[ -f "$STAGE/backup.env" ] ||
		die "no $STAGE/backup.env — $USER_BACKUP already had a key and its secret is lost.
  Delete that key and re-run:
    aws iam list-access-keys --user-name $USER_BACKUP
    aws iam delete-access-key --user-name $USER_BACKUP --access-key-id <id>"

	AWS_ACCESS_KEY_ID=$(awk -F= '/^AWS_ACCESS_KEY_ID=/ { print $2; exit }' "$STAGE/backup.env")
	AWS_SECRET_ACCESS_KEY=$(awk -F= '/^AWS_SECRET_ACCESS_KEY=/ { print $2; exit }' "$STAGE/backup.env")
	[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] ||
		die "$STAGE/backup.env is malformed" 2
	export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
	say "  now acting as $USER_BACKUP ($AWS_ACCESS_KEY_ID), not the admin key"

	# IAM is eventually consistent. A key created seconds ago routinely fails
	# its first few calls with InvalidAccessKeyId, and that failure looks
	# exactly like a wrong key. Retry before believing it.
	init_ok=0
	n=1
	while [ "$n" -le 10 ]; do
		if restic cat config >/dev/null 2>&1; then
			say "  repository already initialised"
			init_ok=1
			break
		fi
		# NOT `restic init | sed`. A pipeline's status is the LAST command's,
		# so sed's unfailing 0 would mask a failed init and this loop would
		# report success on a repository that does not exist.
		init_out=$(restic init --repository-version 2 2>&1)
		init_rc=$?
		printf '%s\n' "$init_out" | sed 's/^/    /'
		if [ "$init_rc" = 0 ]; then
			init_ok=1
			break
		fi
		say "  attempt $n failed (IAM propagation?) — retrying in 6s"
		sleep 6
		n=$((n + 1))
	done
	[ "$init_ok" = 1 ] || die "restic init never succeeded after 10 attempts" 2
fi

# ------------------------------------------------------------------- verify

if [ "$VERIFY" = 1 ] && [ "$DRY_RUN" = 0 ]; then
	step "Policy probes — proving the append-only claim rather than asserting it"

	probe_fail=0

	# A green `restic init` proves the backup credential can WRITE. It proves
	# nothing about what it cannot do, and "cannot delete" is the entire
	# security argument. So probe the negative directly.
	echo probe >"$STAGE/.probe"

	aws s3api put-object --bucket "$BUCKET" --key "_probe/x" \
		--body "$STAGE/.probe" >/dev/null 2>&1 &&
		say "  PASS  backup credential can write" ||
		{ say "  FAIL  backup credential cannot write"; probe_fail=1; }

	if aws s3api delete-object --bucket "$BUCKET" --key "_probe/x" >/dev/null 2>&1; then
		say "  FAIL  backup credential DELETED a data object — the policy is wrong"
		probe_fail=1
	else
		say "  PASS  backup credential refused a delete outside locks/"
	fi

	aws s3api put-object --bucket "$BUCKET" --key "locks/_probe" \
		--body "$STAGE/.probe" >/dev/null 2>&1
	if aws s3api delete-object --bucket "$BUCKET" --key "locks/_probe" >/dev/null 2>&1; then
		say "  PASS  backup credential can delete inside locks/ (restic needs this)"
	else
		say "  FAIL  backup credential cannot clear its own locks — runs will wedge"
		probe_fail=1
	fi

	rm -f "$STAGE/.probe"

	say "  NOTE  _probe/x is still in the bucket. It is ~6 bytes and the prune"
	say "        credential can remove it; the restore test does so as a warm-up."

	[ "$probe_fail" = 0 ] || die "one or more policy probes came back wrong" 3
fi

# --------------------------------------------------------------------- done

step "Install the staged config"

cat <<EOF

  Review first, then install — nothing below has been run:

    ls -l $STAGE
    cat $STAGE/env

    sudo install -d -o root -g wheel -m 700 /etc/tank-offsite
    sudo install -o root -g wheel -m 600 $STAGE/env        /etc/tank-offsite/env
    sudo install -o root -g wheel -m 600 $STAGE/backup.env /etc/tank-offsite/backup.env
    sudo install -o root -g wheel -m 600 $STAGE/repo.pass  /etc/tank-offsite/repo.pass

EOF

step "Three things that must leave this machine"

cat <<EOF

  1. The repository password. A lost one is unrecoverable — there is no reset,
     and the archive becomes 490 GB of noise.

       pass insert -m nas/offsite-repo   # paste the contents of repo.pass
       cat $STAGE/repo.pass              # ...and write it on paper

  2. The bucket name and region: $BUCKET / $REGION
     Store it with the passphrase. It is not a secret; it is the address.

  3. The prune credential, in pass at nas/offsite-prune-aws.

  Put 1 and 2 wherever the tankbak passphrase lives. The scenario this whole
  thing exists for is this machine being gone.

EOF

step "Then revoke the bootstrap key"

cat <<EOF

  It has AdministratorAccess and it has done its job. Leaving it alive is a
  full-account credential sitting in pass for no reason.

    aws iam list-access-keys --user-name "$USER_ADMIN"
    aws iam delete-access-key --user-name "$USER_ADMIN" --access-key-id <id>
    pass rm $PASS_BOOTSTRAP

  Keep the $USER_ADMIN USER — you will want console access. Just not a
  long-lived programmatic key for it.

EOF

say "Done. Next: tank-offsite.sh, then the rehearsal in tests/offsite-rehearsal/."
