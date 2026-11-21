#!/usr/bin/env bash
# Non-interactive worker used by systemd timer and manual manager actions.
set -Eeuo pipefail
umask 077

CONFIG_FILE="${VW_CONFIG_FILE:-/etc/vaultwarden-backup.conf}"
LOG_FILE="${VW_LOG_FILE:-/var/log/vaultwarden-backup.log}"
LOCK_FILE="${VW_LOCK_FILE:-/run/lock/vaultwarden-backup.lock}"
COMMON_LIB="${VW_COMMON_LIB:-/usr/local/libexec/vw-common.sh}"
MANIFEST_TOOL="${VW_MANIFEST_TOOL:-/usr/local/libexec/vw-manifest.py}"
STATE_DIR="/var/lib/vaultwarden-backup"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")" "$STATE_DIR"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"; chmod 700 "$STATE_DIR"
exec >>"$LOG_FILE" 2>&1

echo
echo "===== Vaultwarden backup started: $(date '+%F %T %Z') ====="
exec 9>"$LOCK_FILE"
if ! flock -n 9; then echo "Another backup/restore operation is running; exit without overlap."; exit 0; fi

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: Missing config: $CONFIG_FILE"; exit 1; }
[[ -f "$COMMON_LIB" ]] || { echo "ERROR: Missing common library: $COMMON_LIB"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck disable=SC1090
source "$COMMON_LIB"

# Backward-compatible defaults for configs created by older releases.
SYSTEMD_TIME="${SYSTEMD_TIME:-*-*-* 05:20:00}"
BACKUP_FREQUENCY="${BACKUP_FREQUENCY:-daily}"
MIN_FREE_MB="${MIN_FREE_MB:-512}"
GIT_PUSH_RETRIES="${GIT_PUSH_RETRIES:-3}"
GIT_RETRY_DELAY="${GIT_RETRY_DELAY:-15}"
NOTIFY_METHOD="${NOTIFY_METHOD:-none}"
NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-true}"
NOTIFY_ON_FAILURE="${NOTIFY_ON_FAILURE:-true}"

required_vars=(CONTAINER DATA_DIR AGE_RECIPIENT GITHUB_REPO GITHUB_BRANCH GITHUB_SSH_KEY BACKUP_DIR REPO_DIR RETENTION_DAYS MAX_FILE_MIB)
for var in "${required_vars[@]}"; do [[ -n "${!var:-}" ]] || { echo "ERROR: Config value $var is empty."; exit 1; }; done
for cmd in docker age git sha256sum stat readlink find cp flock date tar gzip awk head du df python3 sqlite3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: Required command missing: $cmd"; exit 1; }
done
[[ -f "$MANIFEST_TOOL" ]] || { echo "ERROR: Missing deployment manifest tool: $MANIFEST_TOOL"; exit 1; }
[[ -f "$GITHUB_SSH_KEY" ]] || { echo "ERROR: GitHub SSH private key not found: $GITHUB_SSH_KEY"; exit 1; }
[[ "$AGE_RECIPIENT" =~ ^age1[[:alnum:]]+$ ]] || { echo "ERROR: AGE_RECIPIENT is not a valid age public-key-shaped value."; exit 1; }
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( RETENTION_DAYS >= 1 )) || { echo "ERROR: RETENTION_DAYS must be positive."; exit 1; }
[[ "$MAX_FILE_MIB" =~ ^[0-9]+$ ]] && (( MAX_FILE_MIB >= 1 && MAX_FILE_MIB <= 95 )) || { echo "ERROR: MAX_FILE_MIB must be 1..95."; exit 1; }
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || { echo "ERROR: MIN_FREE_MB must be an integer."; exit 1; }
[[ "$GIT_PUSH_RETRIES" =~ ^[0-9]+$ ]] && (( GIT_PUSH_RETRIES >= 1 && GIT_PUSH_RETRIES <= 10 )) || { echo "ERROR: GIT_PUSH_RETRIES must be 1..10."; exit 1; }

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
FILENAME="vw-${TIMESTAMP}.tar.gz.age"
MANIFEST_FILENAME="vw-${TIMESTAMP}.manifest.json.age"
OUTPUT="$BACKUP_DIR/$FILENAME"
MANIFEST_OUTPUT="$BACKUP_DIR/$MANIFEST_FILENAME"
TMP_ROOT="$(mktemp -d /var/tmp/vw-backup.XXXXXX)"
STOPPED=0
ARCHIVE_VALIDATED=0
PRESERVE_LOCAL_ARTIFACT=0
FINAL_STATUS="failed"
FAILURE_REASON="backup aborted"

write_result() {
  local status="$1" reason="$2" tmp
  tmp=$(mktemp "$STATE_DIR/last-result.XXXXXX")
  {
    printf 'STATUS=%q\n' "$status"
    printf 'TIMESTAMP=%q\n' "$TIMESTAMP"
    printf 'FINISHED_AT=%q\n' "$(date '+%F %T %Z')"
    printf 'CONTAINER=%q\n' "${CONTAINER:-unknown}"
    printf 'DATA_DIR=%q\n' "${DATA_DIR:-unknown}"
    printf 'BACKUP_FILE=%q\n' "${FILENAME:-unknown}"
    printf 'BACKUP_BYTES=%q\n' "${SIZE_BYTES:-0}"
    printf 'REASON=%q\n' "$reason"
  } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$STATE_DIR/last-result.env"
}

wait_container_healthy() {
  local name="$1" i state health
  for i in $(seq 1 30); do
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$name" 2>/dev/null || echo unknown)
    [[ "$state" == running ]] || { sleep 2; continue; }
    [[ "$health" == unhealthy ]] && { sleep 2; continue; }
    [[ "$health" == starting ]] && { sleep 2; continue; }
    return 0
  done
  echo "ERROR: Container did not reach running/healthy state after start (last state=$state health=$health)."
  return 1
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [[ "$STOPPED" == 1 ]]; then
    echo "CRITICAL: attempting to restart Vaultwarden after backup error..."
    if docker start "$CONTAINER" >/dev/null && wait_container_healthy "$CONTAINER"; then
      STOPPED=0; echo "Vaultwarden restart succeeded."
    else
      echo "CRITICAL: Vaultwarden could not be confirmed healthy. Start/check it in 1Panel immediately."
      vw_notify failure "CRITICAL: Vaultwarden backup task failed and container $CONTAINER could not be confirmed healthy. Check 1Panel immediately."
      rc=1
    fi
  fi
  [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]] && rm -rf -- "$TMP_ROOT"
  if (( rc != 0 )); then
    if [[ "${ARCHIVE_VALIDATED:-0}" != 1 && "${PRESERVE_LOCAL_ARTIFACT:-0}" != 1 ]]; then
      [[ -n "${OUTPUT:-}" ]] && rm -f -- "$OUTPUT" "$OUTPUT.sha256"
      [[ -n "${MANIFEST_OUTPUT:-}" ]] && rm -f -- "$MANIFEST_OUTPUT" "$MANIFEST_OUTPUT.sha256"
    fi
    FAILURE_REASON="${FAILURE_REASON:-exit code $rc}"
    write_result failed "$FAILURE_REASON"
    vw_notify failure "Vaultwarden backup FAILED on $(hostname): $FAILURE_REASON. See /var/log/vaultwarden-backup.log."
  fi
  echo "===== Backup finished with exit code $rc ====="
  exit "$rc"
}
trap on_exit EXIT

# Discover the current container and its data mount every run. DATA_DIR is the
# identity anchor; a different mount is never silently selected.
OLD_CONTAINER="$CONTAINER"; OLD_DATA_DIR="$DATA_DIR"
if ! vw_find_target "$CONTAINER" "$DATA_DIR" true; then FAILURE_REASON="cannot identify unique running Vaultwarden container"; exit 1; fi
CONTAINER="$VW_DETECTED_CONTAINER"; DATA_DIR="$VW_DETECTED_DATA_DIR"
[[ "$CONTAINER" == "$OLD_CONTAINER" ]] || echo "INFO: 1Panel recreated container: $OLD_CONTAINER -> $CONTAINER"
[[ "$DATA_DIR" == "$OLD_DATA_DIR" ]] || echo "INFO: data path updated: $OLD_DATA_DIR -> $DATA_DIR"
if ! vw_save_config; then FAILURE_REASON="could not persist discovered container/data path"; exit 1; fi

echo "Container: $CONTAINER"
echo "Image: $VW_DETECTED_IMAGE"
echo "Health: $VW_DETECTED_HEALTH"
if [[ "$VW_DETECTED_HEALTH" == "unhealthy" ]]; then FAILURE_REASON="Vaultwarden container health is unhealthy before backup"; echo "ERROR: $FAILURE_REASON"; exit 1; fi
echo "Complete /data host path: $DATA_DIR"
[[ -s "$DATA_DIR/db.sqlite3" ]] || { FAILURE_REASON="db.sqlite3 missing or empty"; echo "ERROR: $FAILURE_REASON"; exit 1; }

DATA_CANON=$(readlink -f -- "$DATA_DIR"); BACKUP_CANON=$(readlink -m -- "$BACKUP_DIR"); REPO_CANON=$(readlink -m -- "$REPO_DIR")
paths_overlap() { local a="$1" b="$2"; [[ "$a" == "$b" || "$a" == "$b/"* || "$b" == "$a/"* ]]; }
if paths_overlap "$DATA_CANON" "$BACKUP_CANON" || paths_overlap "$DATA_CANON" "$REPO_CANON" || paths_overlap "$BACKUP_CANON" "$REPO_CANON"; then
  FAILURE_REASON="DATA_DIR, BACKUP_DIR and REPO_DIR overlap"; echo "ERROR: $FAILURE_REASON"; exit 1
fi
AVAILABLE_BYTES=$(df -PB1 "$DATA_DIR" | awk 'NR==2 {print $4}')
MIN_FREE_BYTES=$((MIN_FREE_MB * 1024 * 1024))
if (( AVAILABLE_BYTES < MIN_FREE_BYTES )); then FAILURE_REASON="insufficient free disk space: $(vw_format_bytes "$AVAILABLE_BYTES") available"; echo "ERROR: $FAILURE_REASON"; exit 1; fi
SOURCE_BYTES=$(du -sb "$DATA_DIR" | awk '{print $1}')
DB_BYTES=$(stat -c '%s' "$DATA_DIR/db.sqlite3")
echo "Source /data size: $(vw_format_bytes "$SOURCE_BYTES")"
echo "SQLite db.sqlite3: $(vw_format_bytes "$DB_BYTES")"
echo "Available disk: $(vw_format_bytes "$AVAILABLE_BYTES")"

mkdir -p "$BACKUP_DIR" "$REPO_DIR"; chmod 700 "$BACKUP_DIR" "$REPO_DIR"
[[ -d "$REPO_DIR/.git" ]] || { FAILURE_REASON="Git backup worktree is not initialized"; echo "ERROR: Run setup/configuration first."; exit 1; }
existing_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
[[ "$existing_url" == "$GITHUB_REPO" ]] || { FAILURE_REASON="Git origin differs from configured repository"; echo "ERROR: Configured=$GITHUB_REPO Existing=${existing_url:-<none>}"; exit 1; }
git -C "$REPO_DIR" config user.name "Vaultwarden Backup"
git -C "$REPO_DIR" config user.email "vaultwarden-backup@localhost"
printf -v GIT_SSH_COMMAND 'ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts' "$GITHUB_SSH_KEY"
export GIT_SSH_COMMAND

# Capture sanitized deployment information before stopping the container.
MANIFEST_PLAIN="$TMP_ROOT/deployment-manifest.json"
if ! python3 "$MANIFEST_TOOL" "$CONTAINER" "$MANIFEST_PLAIN"; then FAILURE_REASON="could not create sanitized deployment manifest"; exit 1; fi

# Snapshot the whole /data mount while the app is stopped. All SQLite DB/WAL/SHM
# files and attachments therefore belong to one consistent point in time.
echo "Stopping Vaultwarden briefly to create a consistent /data snapshot..."
if ! docker stop --time 30 "$CONTAINER" >/dev/null; then FAILURE_REASON="docker stop failed"; exit 1; fi
STOPPED=1
if command -v sqlite3 >/dev/null 2>&1; then
  SQLITE_RESULT=$(sqlite3 -readonly "$DATA_DIR/db.sqlite3" 'PRAGMA quick_check;' 2>&1) || { FAILURE_REASON="SQLite quick_check command failed: $SQLITE_RESULT"; echo "ERROR: $FAILURE_REASON"; exit 1; }
  [[ "$SQLITE_RESULT" == "ok" ]] || { FAILURE_REASON="SQLite quick_check failed: $SQLITE_RESULT"; echo "ERROR: $FAILURE_REASON"; exit 1; }
  echo "SQLite quick_check: OK"
else
  echo "WARNING: sqlite3 command missing; DB quick_check skipped."
fi

echo "Creating encrypted complete /data snapshot..."
if ! tar --numeric-owner -czpf - -C "$DATA_DIR" . | age -r "$AGE_RECIPIENT" -o "$OUTPUT"; then FAILURE_REASON="tar/gzip/age pipeline failed"; exit 1; fi
[[ -s "$OUTPUT" ]] || { FAILURE_REASON="encrypted archive is empty"; exit 1; }

# Start the service immediately after snapshot generation, before Git/network work.
echo "Encrypted snapshot created. Restarting Vaultwarden before network upload..."
if ! docker start "$CONTAINER" >/dev/null; then FAILURE_REASON="snapshot made but docker start failed"; exit 1; fi
STOPPED=0
if ! wait_container_healthy "$CONTAINER"; then FAILURE_REASON="container did not become healthy after snapshot"; exit 1; fi

echo "Vaultwarden is running; continuing offline validation and GitHub upload."
HEADER=$(head -n 1 "$OUTPUT" 2>/dev/null || true)
[[ "$HEADER" == "age-encryption.org/v1" ]] || { FAILURE_REASON="output is not a valid age file header"; exit 1; }
SIZE_BYTES=$(stat -c '%s' "$OUTPUT"); MAX_BYTES=$((MAX_FILE_MIB * 1024 * 1024))
echo "Encrypted backup size: $(vw_format_bytes "$SIZE_BYTES")"
if (( SIZE_BYTES > MAX_BYTES )); then
  PRESERVE_LOCAL_ARTIFACT=1
  (cd "$BACKUP_DIR" && sha256sum "$FILENAME" > "$FILENAME.sha256") || true
  FAILURE_REASON="backup exceeds GitHub file size limit (${MAX_FILE_MIB} MiB); encrypted file and SHA256 retained locally at $OUTPUT"
  echo "ERROR: $FAILURE_REASON"
  exit 1
fi

# If the original identity was deliberately kept on this host, perform actual
# decrypt + tar + SQLite validation. This is optional: normal scheduled backup
# requires only the public recipient and does not keep the private key online.
if [[ -n "${AGE_IDENTITY_DEFAULT:-}" && -f "$AGE_IDENTITY_DEFAULT" ]]; then
  ID_PUB=$(age-keygen -y "$AGE_IDENTITY_DEFAULT" 2>/dev/null || true)
  if [[ "$ID_PUB" == "$AGE_RECIPIENT" ]]; then
    VALIDATE_DIR="$TMP_ROOT/validation"; mkdir -p "$VALIDATE_DIR"; chmod 700 "$VALIDATE_DIR"
    if ! age -d -i "$AGE_IDENTITY_DEFAULT" "$OUTPUT" | tar --numeric-owner -xzpf - -C "$VALIDATE_DIR"; then FAILURE_REASON="optional local decrypt/extract validation failed"; exit 1; fi
    [[ -s "$VALIDATE_DIR/db.sqlite3" ]] || { FAILURE_REASON="decrypted backup has no db.sqlite3"; exit 1; }
    SQLITE_RESULT=$(sqlite3 -readonly "$VALIDATE_DIR/db.sqlite3" 'PRAGMA quick_check;' 2>&1) || { FAILURE_REASON="decrypted SQLite quick_check failed: $SQLITE_RESULT"; exit 1; }
    [[ "$SQLITE_RESULT" == "ok" ]] || { FAILURE_REASON="decrypted SQLite quick_check returned: $SQLITE_RESULT"; exit 1; }
    echo "Local age decrypt + tar + SQLite validation: PASS"
  else
    echo "WARNING: AGE_IDENTITY_DEFAULT does not match AGE_RECIPIENT; decrypt validation skipped."
  fi
else
  echo "INFO: age private key is offline/not present; encryption pipeline, age header and SHA256 will be checked. Use menu 'Verify backup' with offline key for a real decryption rehearsal."
fi

# Create separately-encrypted deployment manifest; it contains no secret values.
echo "Encrypting sanitized deployment manifest..."
if ! age -r "$AGE_RECIPIENT" -o "$MANIFEST_OUTPUT" "$MANIFEST_PLAIN"; then FAILURE_REASON="deployment manifest encryption failed"; exit 1; fi
[[ -s "$MANIFEST_OUTPUT" ]] || { FAILURE_REASON="encrypted deployment manifest is empty"; exit 1; }

(cd "$BACKUP_DIR" && sha256sum "$FILENAME" > "$FILENAME.sha256" && sha256sum "$MANIFEST_FILENAME" > "$MANIFEST_FILENAME.sha256")
(cd "$BACKUP_DIR" && sha256sum -c "$FILENAME.sha256" && sha256sum -c "$MANIFEST_FILENAME.sha256")
ARCHIVE_VALIDATED=1

# Refresh the checked-out branch before pruning so recently-added permanent
# keep markers from GitHub are applied to both the working tree and local copy.
REMOTE_HEADS=$(git -C "$REPO_DIR" ls-remote --heads origin "refs/heads/$GITHUB_BRANCH") || { FAILURE_REASON="cannot read GitHub branch before retention cleanup"; exit 1; }
if [[ -n "$REMOTE_HEADS" ]]; then
  git -C "$REPO_DIR" fetch origin "+refs/heads/$GITHUB_BRANCH:refs/remotes/origin/$GITHUB_BRANCH" || { FAILURE_REASON="cannot fetch GitHub branch before retention cleanup"; exit 1; }
  git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$GITHUB_BRANCH" || git -C "$REPO_DIR" switch -c "$GITHUB_BRANCH" --track "origin/$GITHUB_BRANCH" >/dev/null
  git -C "$REPO_DIR" merge --ff-only "origin/$GITHUB_BRANCH" || { FAILURE_REASON="local and remote histories diverged before retention cleanup"; exit 1; }
fi
# Copy remote protection markers to the local backup directory before its
# retention pass. Marker files contain no secrets and are tracked in GitHub.
for marker in "$REPO_DIR"/vw-*.tar.gz.age.keep; do
  [[ -f "$marker" ]] || continue
  marker_name=$(basename "$marker")
  archive_name="${marker_name%.keep}"
  [[ -f "$BACKUP_DIR/$archive_name" ]] && cp -p "$marker" "$BACKUP_DIR/$marker_name"
  manifest_name="${archive_name%.tar.gz.age}.manifest.json.age"
  if [[ -f "$REPO_DIR/$manifest_name.keep" && -f "$BACKUP_DIR/$manifest_name" ]]; then
    cp -p "$REPO_DIR/$manifest_name.keep" "$BACKUP_DIR/$manifest_name.keep"
  fi
done

# Keep the current working tree tidy while honoring explicit .keep markers.
# Removing files from the branch does NOT prune Git's historical objects.
prune_expired_backups() {
  local dir="$1" archive name base manifest
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' archive; do
    name=$(basename -- "$archive")
    base="${name%.tar.gz.age}"
    if [[ -e "$dir/$name.keep" ]]; then
      echo "Retention: protected backup retained: $name"
      continue
    fi
    rm -f -- "$dir/$name" "$dir/$name.sha256"
    manifest="${base}.manifest.json.age"
    if [[ -e "$dir/$manifest.keep" ]]; then
      echo "Retention: protected manifest retained: $manifest"
    else
      rm -f -- "$dir/$manifest" "$dir/$manifest.sha256"
    fi
    echo "Retention: expired backup and paired manifest removed from current directory: $name"
  done < <(find "$dir" -maxdepth 1 -type f -name 'vw-*.tar.gz.age' -mtime "+$RETENTION_DAYS" -print0)
}
prune_expired_backups "$BACKUP_DIR"
cp -p "$OUTPUT" "$REPO_DIR/$FILENAME"; cp -p "$OUTPUT.sha256" "$REPO_DIR/$FILENAME.sha256"
cp -p "$MANIFEST_OUTPUT" "$REPO_DIR/$MANIFEST_FILENAME"; cp -p "$MANIFEST_OUTPUT.sha256" "$REPO_DIR/$MANIFEST_FILENAME.sha256"
prune_expired_backups "$REPO_DIR"

# Synchronize safely with the remote branch; never force-push. Retry transient
# network failures and perform a fast-forward fetch before each subsequent try.
REMOTE_HEADS=$(git -C "$REPO_DIR" ls-remote --heads origin "refs/heads/$GITHUB_BRANCH") || { FAILURE_REASON="cannot read GitHub branch; check SSH Deploy Key/network"; exit 1; }
if [[ -n "$REMOTE_HEADS" ]]; then
  git -C "$REPO_DIR" fetch origin "+refs/heads/$GITHUB_BRANCH:refs/remotes/origin/$GITHUB_BRANCH"
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$GITHUB_BRANCH"; then
    git -C "$REPO_DIR" switch "$GITHUB_BRANCH" >/dev/null 2>&1 || true
    git -C "$REPO_DIR" merge --ff-only "origin/$GITHUB_BRANCH" || { FAILURE_REASON="local and remote Git histories diverged; no force push attempted"; exit 1; }
  else
    git -C "$REPO_DIR" switch -c "$GITHUB_BRANCH" --track "origin/$GITHUB_BRANCH" >/dev/null
  fi
else
  git -C "$REPO_DIR" switch -C "$GITHUB_BRANCH" >/dev/null 2>&1 || git -C "$REPO_DIR" checkout -B "$GITHUB_BRANCH"
fi

git -C "$REPO_DIR" add -A
if ! git -C "$REPO_DIR" diff --cached --quiet; then git -C "$REPO_DIR" commit -m "Vaultwarden encrypted backup ${TIMESTAMP}"; fi
PUSH_OK=0
for attempt in $(seq 1 "$GIT_PUSH_RETRIES"); do
  echo "GitHub push attempt ${attempt}/${GIT_PUSH_RETRIES}..."
  if git -C "$REPO_DIR" push -u origin "$GITHUB_BRANCH"; then PUSH_OK=1; break; fi
  if (( attempt < GIT_PUSH_RETRIES )); then
    echo "Push failed; wait ${GIT_RETRY_DELAY}s, refresh remote, and retry..."
    sleep $((GIT_RETRY_DELAY * attempt))
    if git -C "$REPO_DIR" fetch origin "+refs/heads/$GITHUB_BRANCH:refs/remotes/origin/$GITHUB_BRANCH"; then
      git -C "$REPO_DIR" merge --ff-only "origin/$GITHUB_BRANCH" || { FAILURE_REASON="GitHub history diverged during retry"; exit 1; }
    fi
  fi
done
(( PUSH_OK == 1 )) || { FAILURE_REASON="GitHub push failed after ${GIT_PUSH_RETRIES} attempts; local encrypted backup retained"; exit 1; }
LOCAL_COMMIT=$(git -C "$REPO_DIR" rev-parse "refs/heads/$GITHUB_BRANCH")
REMOTE_COMMIT=$(git -C "$REPO_DIR" ls-remote origin "refs/heads/$GITHUB_BRANCH" | awk 'NR==1 {print $1}')
[[ -n "$REMOTE_COMMIT" && "$LOCAL_COMMIT" == "$REMOTE_COMMIT" ]] || { FAILURE_REASON="remote commit verification mismatch"; exit 1; }

FINAL_STATUS="success"; FAILURE_REASON=""
write_result success "uploaded and remote commit verified"
SUMMARY="Vaultwarden backup SUCCESS on $(hostname). Container: $CONTAINER. File: $FILENAME. Size: $(vw_format_bytes "$SIZE_BYTES"). GitHub remote commit verified."
echo "$SUMMARY"
echo "Manifest: $MANIFEST_FILENAME"
echo "Finished: $(date '+%F %T %Z')"
echo "===== Backup finished successfully ====="
vw_notify success "$SUMMARY"
