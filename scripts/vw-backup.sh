#!/usr/bin/env bash
# Non-interactive backup worker for 1Panel's scheduled task.
# Re-discovers the current Vaultwarden container and /data host path every run.
set -Eeuo pipefail
umask 077

CONFIG_FILE="${VW_CONFIG_FILE:-/etc/vaultwarden-backup.conf}"
LOG_FILE="${VW_LOG_FILE:-/var/log/vaultwarden-backup.log}"
LOCK_FILE="${VW_LOCK_FILE:-/run/lock/vaultwarden-backup.lock}"
COMMON_LIB="${VW_COMMON_LIB:-/usr/local/libexec/vw-common.sh}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

echo
echo "===== Vaultwarden backup started: $(date '+%F %T %Z') ====="

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another backup/restore operation is already running; skip."
  exit 0
fi

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: Missing configuration: $CONFIG_FILE"; exit 1; }
[[ -f "$COMMON_LIB" ]] || { echo "ERROR: Missing helper library: $COMMON_LIB. Reinstall/update the manager scripts from the project menu."; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck disable=SC1090
source "$COMMON_LIB"

required_vars=(CONTAINER DATA_DIR AGE_RECIPIENT GITHUB_REPO GITHUB_BRANCH GITHUB_SSH_KEY BACKUP_DIR REPO_DIR RETENTION_DAYS MAX_FILE_MIB)
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: Configuration value $var is empty."; exit 1; }
done

for cmd in docker age git sha256sum stat readlink find cp flock date tar gzip awk head; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: Required command not found: $cmd"; exit 1; }
done

# Discover current container and /data path each time. If 1Panel has recreated
# the container with a new generated suffix, the old name is ignored safely.
OLD_CONTAINER="$CONTAINER"
OLD_DATA_DIR="$DATA_DIR"
if ! vw_find_target "$CONTAINER" "$DATA_DIR" true; then
  echo "ERROR: Cannot safely identify one running Vaultwarden container. No data was changed."
  exit 1
fi
CONTAINER="$VW_DETECTED_CONTAINER"
DATA_DIR="$VW_DETECTED_DATA_DIR"
if [[ "$CONTAINER" != "$OLD_CONTAINER" ]]; then
  echo "INFO: 1Panel container name changed: $OLD_CONTAINER -> $CONTAINER"
fi
if [[ "$DATA_DIR" != "$OLD_DATA_DIR" ]]; then
  echo "INFO: /data host path changed: $OLD_DATA_DIR -> $DATA_DIR"
fi
# Persist refreshed runtime values for the interactive status page and next run.
if ! vw_save_config; then
  echo "ERROR: Detected target but could not update $CONFIG_FILE. Refusing to continue."
  exit 1
fi

echo "Selected container: $CONTAINER"
echo "Image: $VW_DETECTED_IMAGE"
echo "Container status: $VW_DETECTED_STATUS"
echo "Complete /data host path: $DATA_DIR"

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
[[ -s "$DATA_DIR/db.sqlite3" ]] || { echo "ERROR: db.sqlite3 is missing or empty in $DATA_DIR"; exit 1; }
[[ -f "$GITHUB_SSH_KEY" ]] || { echo "ERROR: GitHub SSH private key not found: $GITHUB_SSH_KEY"; exit 1; }
[[ "$AGE_RECIPIENT" =~ ^age1[[:alnum:]]+$ ]] || { echo "ERROR: AGE_RECIPIENT must be an age public key beginning with age1."; exit 1; }
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((RETENTION_DAYS >= 1)) || { echo "ERROR: RETENTION_DAYS must be a positive integer."; exit 1; }
[[ "$MAX_FILE_MIB" =~ ^[0-9]+$ ]] && ((MAX_FILE_MIB >= 1 && MAX_FILE_MIB <= 95)) || { echo "ERROR: MAX_FILE_MIB must be between 1 and 95."; exit 1; }

SOURCE_BYTES=$(du -sb "$DATA_DIR" | awk '{print $1}')
DB_BYTES=$(stat -c '%s' "$DATA_DIR/db.sqlite3")
echo "Source /data size: $(vw_format_bytes "$SOURCE_BYTES")"
echo "SQLite db.sqlite3 size: $(vw_format_bytes "$DB_BYTES")"
for item in attachments sends config.json rsa_key.pem rsa_key.pub; do
  if [[ -e "$DATA_DIR/$item" ]]; then echo "Found: $item"; fi
done

mkdir -p "$BACKUP_DIR" "$REPO_DIR"
chmod 700 "$BACKUP_DIR" "$REPO_DIR"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: Git backup working directory is not initialized: $REPO_DIR"
  echo "Run the interactive manager menu 1, or check the local backup repository setup."
  exit 1
fi
existing_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
if [[ "$existing_url" != "$GITHUB_REPO" ]]; then
  echo "ERROR: Git origin does not match configured GITHUB_REPO."
  echo "Configured: $GITHUB_REPO"
  echo "Existing:   ${existing_url:-<none>}"
  exit 1
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
  if [[ "$ARCHIVE_READY" == "0" && -f "${OUTPUT:-}" ]]; then rm -f -- "$OUTPUT"; fi
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

# Snapshot consistency: stop the app only for the archive creation window.
echo "Stopping container: $CONTAINER"
docker stop --time 30 "$CONTAINER" >/dev/null
STOPPED=1

# Optional SQLite integrity check while the container is stopped and the database
# files are stable. It is skipped only when sqlite3 CLI is not installed.
if command -v sqlite3 >/dev/null 2>&1; then
  echo "Checking SQLite integrity..."
  SQLITE_RESULT=$(sqlite3 -readonly "$DATA_DIR/db.sqlite3" 'PRAGMA quick_check;' 2>&1) || {
    echo "ERROR: SQLite quick_check command failed: $SQLITE_RESULT"
    exit 1
  }
  if [[ "$SQLITE_RESULT" != "ok" ]]; then
    echo "ERROR: SQLite quick_check did not return 'ok': $SQLITE_RESULT"
    exit 1
  fi
  echo "SQLite integrity: OK"
else
  echo "WARNING: sqlite3 CLI is not installed; database integrity check skipped."
fi

echo "Archiving and encrypting complete /data: $DATA_DIR"
# pipefail ensures tar/gzip errors are not hidden by the age process.
tar --numeric-owner -czpf - -C "$DATA_DIR" . | age -r "$AGE_RECIPIENT" -o "$OUTPUT"
ARCHIVE_READY=1

echo "Encrypted archive created. Restarting Vaultwarden before network upload..."
docker start "$CONTAINER" >/dev/null
STOPPED=0

[[ -s "$OUTPUT" ]] || { echo "ERROR: Encrypted archive is empty."; exit 1; }
HEADER=$(head -n 1 "$OUTPUT" 2>/dev/null || true)
[[ "$HEADER" == "age-encryption.org/v1" ]] || { echo "ERROR: Output does not look like a valid age file."; exit 1; }
SIZE_BYTES=$(stat -c '%s' "$OUTPUT")
MAX_BYTES=$((MAX_FILE_MIB * 1024 * 1024))
echo "Encrypted backup size: $(vw_format_bytes "$SIZE_BYTES")"
if (( SIZE_BYTES > MAX_BYTES )); then
  echo "ERROR: Backup exceeds ${MAX_FILE_MIB} MiB. It is retained locally but will not be pushed to GitHub."
  echo "Use Restic/Rustic with object storage for larger datasets."
  exit 1
fi
if (( SIZE_BYTES < 16384 )); then
  echo "WARNING: Encrypted archive is small (< 16 KiB). This can be normal for an almost-empty Vaultwarden instance. Verify by decrypting a test copy with the original age private key."
fi

(cd "$BACKUP_DIR" && sha256sum "$FILENAME" > "$FILENAME.sha256")
if ! (cd "$BACKUP_DIR" && sha256sum -c "$FILENAME.sha256"); then
  echo "ERROR: Local SHA256 verification failed."
  exit 1
fi

# If the age identity happens to be present locally, perform a real decrypt + tar
# listing test. The design does not require keeping the private key on the VPS.
if [[ -n "${AGE_IDENTITY_DEFAULT:-}" && -f "$AGE_IDENTITY_DEFAULT" ]] && command -v age-keygen >/dev/null 2>&1; then
  ID_PUB=$(age-keygen -y "$AGE_IDENTITY_DEFAULT" 2>/dev/null || true)
  if [[ "$ID_PUB" == "$AGE_RECIPIENT" ]]; then
    MANIFEST=$(mktemp)
    if age -d -i "$AGE_IDENTITY_DEFAULT" "$OUTPUT" | tar -tzf - > "$MANIFEST" && grep -Eq '^\./?db\.sqlite3$' "$MANIFEST"; then
      echo "Optional age decrypt + tar manifest check: PASS"
    else
      rm -f "$MANIFEST"
      echo "ERROR: Optional decrypt/manifest check failed. Backup will not be uploaded."
      exit 1
    fi
    rm -f "$MANIFEST"
  else
    echo "WARNING: local identity does not match configured public key; decrypt test skipped."
  fi
else
  echo "INFO: age private key is not stored on this VPS; cryptographic decrypt test skipped by design."
fi

# Local retention. Do not delete Git history; only remove aged working-tree copies.
CUTOFF_DATE=$(date -d "$RETENTION_DAYS days ago" '+%Y%m%d')
for f in "$BACKUP_DIR"/vw-*.tar.gz.age; do
  [[ -e "$f" ]] || continue
  base=$(basename "$f")
  filedate=${base#vw-}; filedate=${filedate:0:8}
  if [[ "$filedate" =~ ^[0-9]{8}$ && "$filedate" < "$CUTOFF_DATE" ]]; then rm -f -- "$f" "$f.sha256"; fi
done
cp -p "$OUTPUT" "$REPO_DIR/$FILENAME"
cp -p "$OUTPUT.sha256" "$REPO_DIR/$FILENAME.sha256"
for f in "$REPO_DIR"/vw-*.tar.gz.age; do
  [[ -e "$f" ]] || continue
  base=$(basename "$f")
  filedate=${base#vw-}; filedate=${filedate:0:8}
  if [[ "$filedate" =~ ^[0-9]{8}$ && "$filedate" < "$CUTOFF_DATE" ]]; then rm -f -- "$f" "$f.sha256"; fi
done

REMOTE_BRANCH=$(git -C "$REPO_DIR" ls-remote --heads origin "refs/heads/$GITHUB_BRANCH") || {
  echo "ERROR: Cannot read the GitHub branch. Check Deploy Key and repository URL."; exit 1;
}
if [[ -n "$REMOTE_BRANCH" ]]; then
  git -C "$REPO_DIR" fetch origin "+refs/heads/$GITHUB_BRANCH:refs/remotes/origin/$GITHUB_BRANCH"
  if git -C "$REPO_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$REPO_DIR" merge --ff-only "origin/$GITHUB_BRANCH" || {
      echo "ERROR: Local and remote histories diverged. No force push was attempted."; exit 1;
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

LOCAL_COMMIT=$(git -C "$REPO_DIR" rev-parse "refs/heads/$GITHUB_BRANCH")
REMOTE_COMMIT=$(git -C "$REPO_DIR" ls-remote origin "refs/heads/$GITHUB_BRANCH" | awk 'NR==1 {print $1}')
[[ -n "$REMOTE_COMMIT" && "$LOCAL_COMMIT" == "$REMOTE_COMMIT" ]] || {
  echo "ERROR: Push returned, but remote branch verification did not match local commit."; exit 1;
}

echo "SUCCESS: encrypted backup uploaded and remote commit verified."
echo "Container: $CONTAINER"
echo "Data directory: $DATA_DIR"
echo "File: $FILENAME"
echo "Size: $(vw_format_bytes "$SIZE_BYTES")"
echo "Finished: $(date '+%F %T %Z')"
echo "===== Backup finished ====="
