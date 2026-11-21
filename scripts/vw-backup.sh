#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CONFIG_FILE="/etc/vaultwarden-backup.conf"
LOG_FILE="/var/log/vaultwarden-backup.log"
LOCK_FILE="/run/lock/vaultwarden-backup.lock"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

echo
echo "===== Vaultwarden backup started: $(date '+%F %T %Z') ====="

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another backup is already running; skip."
  exit 0
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Missing configuration: $CONFIG_FILE"
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

required_vars=(CONTAINER DATA_DIR AGE_RECIPIENT GITHUB_REPO GITHUB_BRANCH GITHUB_SSH_KEY BACKUP_DIR REPO_DIR RETENTION_DAYS MAX_FILE_MIB)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Configuration value $var is empty."
    exit 1
  fi
done

for cmd in docker age tar git sha256sum stat readlink find cp flock date; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $cmd"
    exit 1
  }
done

[[ -d "$DATA_DIR" ]] || { echo "ERROR: DATA_DIR not found: $DATA_DIR"; exit 1; }
DATA_CANON=$(readlink -f -- "$DATA_DIR")
BACKUP_CANON=$(readlink -m -- "$BACKUP_DIR")
REPO_CANON=$(readlink -m -- "$REPO_DIR")
paths_overlap() {
  local a="$1" b="$2"
  [[ "$a" == "$b" || "$a" == "$b/"* || "$b" == "$a/"* ]]
}
if paths_overlap "$DATA_CANON" "$BACKUP_CANON" || paths_overlap "$DATA_CANON" "$REPO_CANON" || paths_overlap "$BACKUP_CANON" "$REPO_CANON"; then
  echo "ERROR: DATA_DIR, BACKUP_DIR and REPO_DIR must be independent, non-overlapping directories."
  exit 1
fi
[[ "$DATA_CANON" != "/" && "$DATA_CANON" != "/var/lib/docker" ]] || {
  echo "ERROR: DATA_DIR is an unsafe system-level directory; refusing to continue."
  exit 1
}
[[ -f "$DATA_DIR/db.sqlite3" ]] || {
  echo "ERROR: db.sqlite3 not found in DATA_DIR. This package expects the SQLite edition. Do not continue if your installation uses another database."
  exit 1
}
[[ -f "$GITHUB_SSH_KEY" ]] || { echo "ERROR: GitHub SSH private key not found: $GITHUB_SSH_KEY"; exit 1; }
[[ "$AGE_RECIPIENT" == age1* ]] || { echo "ERROR: AGE_RECIPIENT must be an age public key beginning with age1."; exit 1; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: Container not found: $CONTAINER"
  exit 1
fi

MOUNT_SOURCE=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
if [[ -z "$MOUNT_SOURCE" ]]; then
  echo "ERROR: No mount at container path /data. Check docker inspect output before continuing."
  exit 1
fi
if [[ "$(readlink -f "$MOUNT_SOURCE")" != "$(readlink -f "$DATA_DIR")" ]]; then
  echo "ERROR: Container /data source ($MOUNT_SOURCE) does not match DATA_DIR ($DATA_DIR)."
  echo "Correct /etc/vaultwarden-backup.conf using the exact Source shown by docker inspect."
  exit 1
fi

RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER")
if [[ "$RUNNING" != "true" ]]; then
  echo "ERROR: Vaultwarden container is not running. No backup created."
  exit 1
fi

mkdir -p "$BACKUP_DIR" "$REPO_DIR"
chmod 700 "$BACKUP_DIR" "$REPO_DIR"

# This script expects a new, empty GitHub repository (no README/license/.gitignore).
# Keep REPO_DIR between runs; it contains the local Git history and remote tracking state.
if [[ ! -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" init -b "$GITHUB_BRANCH"
  git -C "$REPO_DIR" remote add origin "$GITHUB_REPO"
fi
if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
  git -C "$REPO_DIR" remote add origin "$GITHUB_REPO"
else
  git -C "$REPO_DIR" remote set-url origin "$GITHUB_REPO"
fi

git -C "$REPO_DIR" config user.name "Vaultwarden Backup"
git -C "$REPO_DIR" config user.email "vaultwarden-backup@localhost"

printf -v GIT_SSH_COMMAND 'ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts' "$GITHUB_SSH_KEY"
export GIT_SSH_COMMAND

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
FILENAME="vw-${TIMESTAMP}.tar.gz.age"
OUTPUT="$BACKUP_DIR/$FILENAME"
STOPPED=0
ARCHIVE_READY=0

cleanup() {
  rc=$?
  if [[ "$ARCHIVE_READY" == "0" && -f "${OUTPUT:-}" ]]; then
    rm -f -- "$OUTPUT"
  fi
  if [[ "$STOPPED" == "1" ]]; then
    echo "Safety action: attempting to start Vaultwarden after backup error..."
    if docker start "$CONTAINER" >/dev/null; then
      STOPPED=0
      echo "Vaultwarden is running again."
    else
      echo "CRITICAL: Could not restart Vaultwarden. Open 1Panel and start the application/container manually."
      rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

# Stop only the Vaultwarden container. This gives SQLite and attachments a consistent
# point-in-time snapshot. Keep the stop window limited to archive creation.
echo "Stopping container: $CONTAINER"
docker stop --time 30 "$CONTAINER" >/dev/null
STOPPED=1

echo "Archiving and encrypting the complete /data mount: $DATA_DIR"
# Archive contents, including db.sqlite3, WAL/SHM files if present, attachments, sends,
# config.json and RSA keys. The plaintext archive is streamed directly into age.
tar --numeric-owner -czpf - -C "$DATA_DIR" . | age -r "$AGE_RECIPIENT" -o "$OUTPUT"
ARCHIVE_READY=1

echo "Starting Vaultwarden immediately after snapshot creation..."
docker start "$CONTAINER" >/dev/null
STOPPED=0

test -s "$OUTPUT" || { echo "ERROR: Encrypted backup is empty."; exit 1; }
SIZE_BYTES=$(stat -c '%s' "$OUTPUT")
MAX_BYTES=$((MAX_FILE_MIB * 1024 * 1024))
echo "Encrypted backup size: $((SIZE_BYTES / 1024 / 1024)) MiB"
if (( SIZE_BYTES > MAX_BYTES )); then
  echo "ERROR: Backup exceeds ${MAX_FILE_MIB} MiB. Kept locally but not pushed. Use Restic/object storage for larger backups."
  exit 1
fi

# Generate a portable checksum that works after downloading to another directory.
(cd "$BACKUP_DIR" && sha256sum "$FILENAME" > "$FILENAME.sha256")

# Retain local encrypted copies for RETENTION_DAYS.
CUTOFF_DATE=$(date -d "$RETENTION_DAYS days ago" '+%Y%m%d')
for f in "$BACKUP_DIR"/vw-*.tar.gz.age; do
  [[ -e "$f" ]] || continue
  base=$(basename "$f")
  filedate=${base#vw-}
  filedate=${filedate:0:8}
  if [[ "$filedate" =~ ^[0-9]{8}$ ]] && [[ "$filedate" < "$CUTOFF_DATE" ]]; then
    rm -f -- "$f" "$f.sha256"
  fi
done

cp -p "$OUTPUT" "$REPO_DIR/$FILENAME"
cp -p "$OUTPUT.sha256" "$REPO_DIR/$FILENAME.sha256"

# Remove old backup files from the current GitHub branch tree. Note: Git commit history
# still retains old blobs; the repository itself can continue growing over time.
for f in "$REPO_DIR"/vw-*.tar.gz.age; do
  [[ -e "$f" ]] || continue
  base=$(basename "$f")
  filedate=${base#vw-}
  filedate=${filedate:0:8}
  if [[ "$filedate" =~ ^[0-9]{8}$ ]] && [[ "$filedate" < "$CUTOFF_DATE" ]]; then
    rm -f -- "$f" "$f.sha256"
  fi
done

# Synchronize with the remote branch before adding this backup. The setup wizard
# clones an existing remote history; this fast-forward check prevents overwriting
# changes made through GitHub or another backup host.
REMOTE_BRANCH=$(git -C "$REPO_DIR" ls-remote --heads origin "refs/heads/$GITHUB_BRANCH") || {
  echo "ERROR: Cannot read the remote GitHub branch. Check the Deploy Key and repository URL."
  exit 1
}
if [[ -n "$REMOTE_BRANCH" ]]; then
  git -C "$REPO_DIR" fetch origin "+refs/heads/$GITHUB_BRANCH:refs/remotes/origin/$GITHUB_BRANCH"
  if git -C "$REPO_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$REPO_DIR" merge --ff-only "origin/$GITHUB_BRANCH" || {
      echo "ERROR: Local and remote backup histories have diverged. No force push was attempted."
      exit 1
    }
  else
    git -C "$REPO_DIR" checkout -B "$GITHUB_BRANCH" "origin/$GITHUB_BRANCH"
  fi
fi

git -C "$REPO_DIR" add -A
if ! git -C "$REPO_DIR" diff --cached --quiet; then
  git -C "$REPO_DIR" commit -m "Encrypted Vaultwarden backup ${TIMESTAMP}"
fi

git -C "$REPO_DIR" push -u origin "$GITHUB_BRANCH"

echo "SUCCESS: encrypted backup uploaded to GitHub."
echo "File: $FILENAME"
echo "Finished: $(date '+%F %T %Z')"
echo "===== Backup finished ====="
