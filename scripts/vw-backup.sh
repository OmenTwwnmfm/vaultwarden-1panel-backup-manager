#!/usr/bin/env bash
# Non-interactive worker used by systemd timer and manual manager actions.
set -Eeuo pipefail
umask 077

CONFIG_FILE="${VW_CONFIG_FILE:-/etc/vaultwarden-backup.conf}"
LOG_FILE="${VW_LOG_FILE:-/var/log/vaultwarden-backup.log}"
LOCK_FILE="${VW_LOCK_FILE:-/run/lock/vaultwarden-backup.lock}"
COMMON_LIB="${VW_COMMON_LIB:-/usr/local/libexec/vw-common.sh}"
MANIFEST_TOOL="${VW_MANIFEST_TOOL:-/usr/local/libexec/vw-manifest.py}"
STORAGE_TOOL="$(dirname -- "${BASH_SOURCE[0]}")/vw-storage.py"
[[ -f "$STORAGE_TOOL" ]] || STORAGE_TOOL="/usr/local/libexec/vw-storage.py"
STATE_DIR="${VW_STATE_DIR:-/var/lib/vaultwarden-backup}"
# Trust anchor (root only): the VW_* overrides above stay available so the
# manager and tests can relocate paths, but when this worker runs as root
# the code it is about to load must be root-owned and not writable by
# group/other users, and the log/lock/state paths must not be symlinks.
# Without this, a crafted environment could redirect code execution.
if (( EUID == 0 )); then
  code_file_trusted() {
    [[ -f "$1" && ! -L "$1" && "$(stat -c '%u' -- "$1")" == 0 ]] && (( (8#$(stat -c '%a' -- "$1") & 022) == 0 ))
  }
  # The common library is sourced below, so it must exist and be trusted.
  if ! code_file_trusted "$COMMON_LIB"; then
    echo "ERROR: Refusing to load a code file that is not root-owned and locked down: $COMMON_LIB" >&2
    exit 1
  fi
  # Tools run later in the flow: when present they must be trusted too.
  # A missing tool keeps the existing later "missing tool" error path.
  for code_file in "$MANIFEST_TOOL" "$STORAGE_TOOL"; do
    if [[ -e "$code_file" || -L "$code_file" ]] && ! code_file_trusted "$code_file"; then
      echo "ERROR: Refusing to load a code file that is not root-owned and locked down: $code_file" >&2
      exit 1
    fi
  done
  for link_path in "$LOG_FILE" "$LOCK_FILE" "$STATE_DIR"; do
    if [[ -L "$link_path" ]]; then
      echo "ERROR: Refusing symlink path: $link_path" >&2
      exit 1
    fi
  done
fi
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")" "$STATE_DIR"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"; chmod 700 "$STATE_DIR"
exec >>"$LOG_FILE" 2>&1

echo
echo "===== Vaultwarden backup started: $(date '+%F %T %Z') ====="
RUN_ID="${VW_RUN_ID:-$(date '+%Y%m%d-%H%M%S')-$$}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || { echo "ERROR: Invalid run ID."; exit 2; }
RUN_RESULT_DIR="$STATE_DIR/runs"
mkdir -p "$RUN_RESULT_DIR"
chmod 700 "$RUN_RESULT_DIR"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
SNAPSHOT_CREATED=false
LOCAL_VERIFIED=false
DECRYPT_VERIFIED=false
SERVICE_RESTORED=false
REMOTE_VERIFIED=false
REMOTE_VERIFIED_GITHUB=false
REMOTE_VERIFIED_WEBDAV=false
CONTAINER="unknown"
DATA_DIR="unknown"
FILENAME="unknown"
SIZE_BYTES=0
VALIDATE_DIR=""
OUTPUT_CREATED=false
MANIFEST_CREATED=false
MANIFEST_COMPLETE=false
MANIFEST_VERIFIED=false

write_result() {
  local status="$1" reason="$2" publish_last="${3:-true}" target tmp
  target="$RUN_RESULT_DIR/$RUN_ID.env"
  tmp=$(mktemp "${target}.XXXXXX") || return 1
  {
    printf 'STATUS=%q\n' "$status"
    printf 'RUN_ID=%q\n' "$RUN_ID"
    printf 'TIMESTAMP=%q\n' "$TIMESTAMP"
    printf 'FINISHED_AT=%q\n' "$(date '+%F %T %Z')"
    printf 'CONTAINER=%q\n' "$CONTAINER"
    printf 'DATA_DIR=%q\n' "$DATA_DIR"
    printf 'BACKUP_FILE=%q\n' "$FILENAME"
    printf 'BACKUP_BYTES=%q\n' "$SIZE_BYTES"
    printf 'SNAPSHOT_CREATED=%q\n' "$SNAPSHOT_CREATED"
    printf 'OUTPUT_CREATED=%q\n' "$OUTPUT_CREATED"
    printf 'MANIFEST_COMPLETE=%q\n' "$MANIFEST_COMPLETE"
    printf 'MANIFEST_VERIFIED=%q\n' "$MANIFEST_VERIFIED"
    printf 'LOCAL_VERIFIED=%q\n' "$LOCAL_VERIFIED"
    printf 'DECRYPT_VERIFIED=%q\n' "$DECRYPT_VERIFIED"
    printf 'SERVICE_RESTORED=%q\n' "$SERVICE_RESTORED"
    printf 'REMOTE_VERIFIED=%q\n' "$REMOTE_VERIFIED"
    printf 'REMOTE_VERIFIED_GITHUB=%q\n' "$REMOTE_VERIFIED_GITHUB"
    printf 'REMOTE_VERIFIED_WEBDAV=%q\n' "$REMOTE_VERIFIED_WEBDAV"
    printf 'BACKUP_TARGET=%q\n' "${UPLOAD_TARGET:-${BACKUP_TARGET:-github}}"
    printf 'REASON=%q\n' "$reason"
  } > "$tmp"
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if (( EUID == 0 )); then chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }; fi
  vw_atomic_replace "$tmp" "$target" || { rm -f -- "$tmp"; return 1; }
  if [[ "$publish_last" == true ]]; then
    tmp=$(mktemp "$STATE_DIR/last-result.XXXXXX") || return 1
    cp -- "$target" "$tmp"
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    if (( EUID == 0 )); then chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }; fi
    vw_atomic_replace "$tmp" "$STATE_DIR/last-result.env" || { rm -f -- "$tmp"; return 1; }
  fi
}

# shellcheck disable=SC1090
source "$COMMON_LIB"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another backup/restore operation is running; this run was skipped."
  write_result skipped "another backup/restore operation holds the lock" false || echo "ERROR: Could not record skipped run."
  exit 75
fi

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: Missing config: $CONFIG_FILE"; exit 1; }
[[ -f "$COMMON_LIB" ]] || { echo "ERROR: Missing common library: $COMMON_LIB"; exit 1; }
vw_require_secure_config "$CONFIG_FILE" || exit 1
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Backward-compatible defaults for configs created by older releases.
SYSTEMD_TIME="${SYSTEMD_TIME:-*-*-* 05:20:00}"
BACKUP_FREQUENCY="${BACKUP_FREQUENCY:-daily}"
MIN_FREE_MB="${MIN_FREE_MB:-512}"
GIT_PUSH_RETRIES="${GIT_PUSH_RETRIES:-3}"
GIT_RETRY_DELAY="${GIT_RETRY_DELAY:-15}"
NOTIFY_METHOD="${NOTIFY_METHOD:-none}"
NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-true}"
NOTIFY_ON_FAILURE="${NOTIFY_ON_FAILURE:-true}"
BACKUP_TARGET="${PRIMARY_TARGET:-${BACKUP_TARGET:-github}}"
UPLOAD_TARGET="${1:-$BACKUP_TARGET}"
SECONDARY_TARGET="${SECONDARY_TARGET:-none}"
SNAPSHOT_MODE="${SNAPSHOT_MODE:-stop}"
[[ "$SECONDARY_TARGET" == none || "$SECONDARY_TARGET" == github || "$SECONDARY_TARGET" == webdav ]] || exit 2
[[ "$SNAPSHOT_MODE" == stop || "$SNAPSHOT_MODE" == online ]] || exit 2
[[ "$UPLOAD_TARGET" == github || "$UPLOAD_TARGET" == webdav ]] || { echo "ERROR: Backup target must be github or webdav."; exit 2; }
REPO_DIR="${REPO_DIR:-/opt/vw-github-repo}"
MAX_FILE_MIB="${MAX_FILE_MIB:-90}"

required_vars=(CONTAINER DATA_DIR AGE_RECIPIENT BACKUP_DIR RETENTION_DAYS)
for var in "${required_vars[@]}"; do [[ -n "${!var:-}" ]] || { echo "ERROR: Config value $var is empty."; exit 1; }; done
for cmd in docker age sha256sum stat readlink find cp flock date tar gzip awk head du df python3 sqlite3 timeout; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: Required command missing: $cmd"; exit 1; }
done
[[ -f "$MANIFEST_TOOL" ]] || { echo "ERROR: Missing deployment manifest tool: $MANIFEST_TOOL"; exit 1; }
python3 "$STORAGE_TOOL" check-signing --deploy-key "${GITHUB_SSH_KEY:-}" || exit 1
[[ "$AGE_RECIPIENT" =~ ^age1[[:alnum:]]+$ ]] || { echo "ERROR: AGE_RECIPIENT is not a valid age public-key-shaped value."; exit 1; }
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( RETENTION_DAYS >= 1 )) || { echo "ERROR: RETENTION_DAYS must be positive."; exit 1; }
[[ "$MAX_FILE_MIB" =~ ^[0-9]+$ ]] && (( MAX_FILE_MIB >= 1 && MAX_FILE_MIB <= 95 )) || { echo "ERROR: MAX_FILE_MIB must be 1..95."; exit 1; }
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || { echo "ERROR: MIN_FREE_MB must be an integer."; exit 1; }
[[ "$GIT_PUSH_RETRIES" =~ ^[0-9]+$ ]] && (( GIT_PUSH_RETRIES >= 1 && GIT_PUSH_RETRIES <= 10 )) || { echo "ERROR: GIT_PUSH_RETRIES must be 1..10."; exit 1; }

VW_PERF_FILE="${VW_PERF_FILE:-/var/lib/vaultwarden-backup/performance.tsv}"
export VW_PERF_FILE
vw_perf_init backup "$RUN_ID"
echo "Performance records: ${VW_PERF_FILE}"
vw_perf_stage_begin "container_discovery_preflight"
FILENAME="vw-${TIMESTAMP}.tar.gz.age"
MANIFEST_FILENAME="vw-${TIMESTAMP}.manifest.json.age"
OUTPUT="$BACKUP_DIR/$FILENAME"
MANIFEST_OUTPUT="$BACKUP_DIR/$MANIFEST_FILENAME"
TMP_ROOT="$(mktemp -d /var/tmp/vw-backup.XXXXXX)"
STOPPED=0
SNAPSHOT_CREATED=false
LOCAL_VERIFIED=false
DECRYPT_VERIFIED=false
SERVICE_RESTORED=false
REMOTE_VERIFIED=false
OUTPUT_CREATED=false
MANIFEST_CREATED=false
MANIFEST_COMPLETE=false
MANIFEST_VERIFIED=false
FINAL_STATUS="failed"
FAILURE_REASON="backup aborted"

wait_container_healthy() {
  local name="$1" timeout_s="${2:-120}" delay_s="${3:-2}" consecutive="${4:-2}"
  vw_wait_healthy "$name" "$timeout_s" "$delay_s" "$consecutive"
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [[ "$STOPPED" == 1 ]]; then
    echo "CRITICAL: attempting to restart Vaultwarden after backup error..."
    vw_perf_stage_begin "recovery_container_start_command"
    if docker start "$CONTAINER" >/dev/null; then
      STOPPED=0
      vw_perf_stage_end success
      vw_perf_stage_begin "recovery_health_check_wait"
      local health_rc=0
      if wait_container_healthy "$CONTAINER" 120 2 2; then health_rc=0; else health_rc=$?; fi
      vw_perf_stage_end aggregate
      if (( health_rc == 0 )); then
        SERVICE_RESTORED=true
        vw_perf_downtime_end success
        echo "Vaultwarden restart succeeded."
      else
        vw_perf_downtime_end failed
        echo "CRITICAL: Vaultwarden could not be confirmed healthy. Start/check it in 1Panel immediately."
        vw_notify failure "CRITICAL: Vaultwarden backup task failed and container $CONTAINER could not be confirmed healthy. Check 1Panel immediately." || true
        rc=1
      fi
    else
      vw_perf_stage_end failed
      vw_perf_downtime_end failed
      echo "CRITICAL: docker start failed. Start/check Vaultwarden in 1Panel immediately."
      vw_notify failure "CRITICAL: Vaultwarden backup task failed and docker start failed for $CONTAINER. Check 1Panel immediately." || true
      rc=1
    fi
  fi
  if [[ -n "${VW_PERF_DOWNTIME_START_MS:-}" ]]; then vw_perf_downtime_end aggregate; fi
  [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]] && rm -rf -- "$TMP_ROOT"
  [[ -n "${VALIDATE_DIR:-}" && -d "$VALIDATE_DIR" ]] && rm -rf -- "$VALIDATE_DIR"
  if [[ "${VW_PERF_STARTED:-0}" == 1 && "${VW_PERF_FINISHED:-0}" != 1 ]]; then
    if (( rc == 0 )); then vw_perf_finish success; else vw_perf_finish failed; fi
  fi
  if (( rc != 0 )); then
    if [[ "${SNAPSHOT_CREATED:-false}" != true && "${OUTPUT_CREATED:-false}" == true ]]; then
      rm -f -- "$OUTPUT" "$OUTPUT.sha256"
    fi
    if [[ "${MANIFEST_CREATED:-false}" == true ]]; then
      if [[ "${MANIFEST_COMPLETE:-false}" != true ]]; then
        rm -f -- "$MANIFEST_OUTPUT" "$MANIFEST_OUTPUT.sha256"
      elif [[ "${MANIFEST_VERIFIED:-false}" != true ]]; then
        rm -f -- "$MANIFEST_OUTPUT.sha256"
      fi
    fi
    FAILURE_REASON="${FAILURE_REASON:-exit code $rc}"
    write_result failed "$FAILURE_REASON" || echo "ERROR: Could not write final run result."
    vw_notify failure "Vaultwarden backup FAILED on $(hostname): $FAILURE_REASON. See /var/log/vaultwarden-backup.log." || true
  elif [[ "${FINAL_STATUS:-failed}" == success ]]; then
    write_result success "uploaded and $UPLOAD_TARGET remote verified" || echo "ERROR: Could not write final run result."
  fi
  echo "===== Backup finished with exit code $rc ====="
  exit "$rc"
}
trap on_exit EXIT
write_result running "backup started" || { FAILURE_REASON="could not record run state"; exit 1; }
if [[ -e "$OUTPUT" || -e "$MANIFEST_OUTPUT" ]]; then
  FAILURE_REASON="output filename already exists; refusing to overwrite an earlier artifact"
  echo "ERROR: $FAILURE_REASON"
  exit 1
fi

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
UNSUPPORTED_ENTRY=$(find "$DATA_DIR" -mindepth 1 \( -type l -o -type b -o -type c -o -type p -o \( -type f -links +1 \) -o -perm /6000 \) -print -quit)
if [[ -n "$UNSUPPORTED_ENTRY" ]]; then
  FAILURE_REASON="/data contains a link or special permission/file type that secure restore does not accept: $UNSUPPORTED_ENTRY"
  echo "ERROR: $FAILURE_REASON"
  exit 1
fi

DATA_CANON=$(readlink -f -- "$DATA_DIR"); BACKUP_CANON=$(readlink -m -- "$BACKUP_DIR")
paths_overlap() { local a="$1" b="$2"; [[ "$a" == "$b" || "$a" == "$b/"* || "$b" == "$a/"* ]]; }
if paths_overlap "$DATA_CANON" "$BACKUP_CANON"; then
  FAILURE_REASON="DATA_DIR and BACKUP_DIR overlap"; echo "ERROR: $FAILURE_REASON"; exit 1
fi
if [[ "$UPLOAD_TARGET" == github || "$SECONDARY_TARGET" == github || -d "$STATE_DIR/pending/github" ]]; then
  REPO_CANON=$(readlink -m -- "$REPO_DIR")
  if paths_overlap "$DATA_CANON" "$REPO_CANON" || paths_overlap "$BACKUP_CANON" "$REPO_CANON"; then
    FAILURE_REASON="DATA_DIR, BACKUP_DIR and REPO_DIR overlap"; echo "ERROR: $FAILURE_REASON"; exit 1
  fi
fi
MIN_FREE_BYTES=$((MIN_FREE_MB * 1024 * 1024))
SOURCE_BYTES=$(du -sb "$DATA_DIR" | awk '{print $1}')
DB_BYTES=$(stat -c '%s' "$DATA_DIR/db.sqlite3")
echo "Source /data size: $(vw_format_bytes "$SOURCE_BYTES")"
echo "SQLite db.sqlite3: $(vw_format_bytes "$DB_BYTES")"

mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
vw_require_free_space "$DATA_DIR" "$MIN_FREE_BYTES" "数据盘" || { FAILURE_REASON="insufficient free space on DATA_DIR filesystem"; exit 1; }
BACKUP_REQUIRED_BYTES=$(( SOURCE_BYTES + SOURCE_BYTES / 5 ))
if (( BACKUP_REQUIRED_BYTES < MIN_FREE_BYTES )); then BACKUP_REQUIRED_BYTES="$MIN_FREE_BYTES"; fi
vw_require_free_space "$BACKUP_DIR" "$BACKUP_REQUIRED_BYTES" "本地备份目录" || { FAILURE_REASON="insufficient free space on BACKUP_DIR filesystem"; exit 1; }
vw_require_free_space /var/tmp "$MIN_FREE_BYTES" "临时目录" || { FAILURE_REASON="insufficient free space on temporary filesystem"; exit 1; }
AVAILABLE_BYTES=$(df -PB1 -- "$BACKUP_DIR" | awk 'NR==2 {print $4}')
echo "Available backup disk: $(vw_format_bytes "$AVAILABLE_BYTES")"
upload_snapshot() (
  local target="$1" archive="$2" name manifest member remote_head local_head attempt existing_url
  python3 "$STORAGE_TOOL" verify-signature "$archive" || return 1
  manifest="${archive%.tar.gz.age}.manifest.json.age"
  python3 "$STORAGE_TOOL" verify-signature "$manifest" || return 1
  if [[ "$target" == webdav ]]; then
    python3 "$STORAGE_TOOL" upload "$archive"
    return $?
  fi
  [[ -d "$REPO_DIR/.git" && -n "${GITHUB_REPO:-}" && -n "${GITHUB_BRANCH:-}" && -f "${GITHUB_SSH_KEY:-}" ]] || { echo "GitHub target configuration is incomplete."; return 1; }
  name=$(basename -- "$archive") || return 1
  (( $(stat -c '%s' "$archive") <= MAX_FILE_MIB * 1024 * 1024 )) || { echo "Backup exceeds GitHub file size limit."; return 1; }
  vw_require_free_space "$REPO_DIR" "$MIN_FREE_BYTES" "Git 仓库目录" || return 1
  existing_url=$(git -C "$REPO_DIR" remote get-url origin) || return 1
  [[ "$existing_url" == "$GITHUB_REPO" ]] || { echo "GitHub worktree origin does not match the backup configuration."; return 1; }
  printf -v GIT_SSH_COMMAND 'ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts' "$GITHUB_SSH_KEY"
  export GIT_SSH_COMMAND
  remote_head=$(git -C "$REPO_DIR" ls-remote --heads origin "refs/heads/$GITHUB_BRANCH") || return 1
  if [[ -n "$remote_head" ]]; then
    git -C "$REPO_DIR" fetch origin "+refs/heads/$GITHUB_BRANCH:refs/remotes/origin/$GITHUB_BRANCH" || return 1
    if ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$GITHUB_BRANCH"; then
      git -C "$REPO_DIR" switch -c "$GITHUB_BRANCH" --track "origin/$GITHUB_BRANCH" || return 1
    fi
  fi
  [[ "$(git -C "$REPO_DIR" branch --show-current)" == "$GITHUB_BRANCH" ]] || git -C "$REPO_DIR" switch "$GITHUB_BRANCH" || return 1
  if [[ -n "$remote_head" ]]; then git -C "$REPO_DIR" merge --ff-only "origin/$GITHUB_BRANCH" || return 1; fi
  git -C "$REPO_DIR" diff --cached --quiet || return 1
  local -a members=()
  for member in "$archive" "$archive.sha256" "$archive.sha256.sig" "$manifest" "$manifest.sha256" "$manifest.sha256.sig"; do
    local destination
    destination="$REPO_DIR/$(basename -- "$member")"
    if [[ -e "$destination" || -L "$destination" ]]; then
      [[ -f "$destination" && ! -L "$destination" ]] && cmp -s -- "$member" "$destination" || return 1
    else
      cp -p -- "$member" "$destination" || return 1
    fi
    members+=("$(basename -- "$member")")
  done
  git -C "$REPO_DIR" add -- "${members[@]}" || return 1
  if ! git -C "$REPO_DIR" diff --cached --quiet; then
    git -C "$REPO_DIR" commit -m "Vaultwarden encrypted backup $name" || return 1
  fi
  for ((attempt=1; attempt<=GIT_PUSH_RETRIES; attempt++)); do
    if git -C "$REPO_DIR" push origin "$GITHUB_BRANCH"; then
      local_head=$(git -C "$REPO_DIR" rev-parse HEAD) || return 1
      remote_head=$(git -C "$REPO_DIR" ls-remote --heads origin "refs/heads/$GITHUB_BRANCH") || return 1
      [[ "${remote_head%%$'\t'*}" == "$local_head" ]] || return 1
      for member in "${members[@]}"; do
        git -C "$REPO_DIR" show "$local_head:$member" | cmp -s -- "$BACKUP_DIR/$member" - || return 1
      done
      printf '%s\n' "$local_head" > "$TMP_ROOT/github-verified-commit"
      return $?
    fi
    if ((attempt < GIT_PUSH_RETRIES)); then
      echo "GitHub push attempt $attempt failed; refreshing remote state before retry."
      sleep "$GIT_RETRY_DELAY"
      git -C "$REPO_DIR" fetch origin "+refs/heads/$GITHUB_BRANCH:refs/remotes/origin/$GITHUB_BRANCH" || return 1
      if ! git -C "$REPO_DIR" rebase "origin/$GITHUB_BRANCH"; then
        git -C "$REPO_DIR" rebase --abort >/dev/null 2>&1 || true
        echo "GitHub push retry could not rebase onto the latest remote branch." >&2
        return 1
      fi
    fi
  done
  return 1
)

try_pending_upload() {
  local target="$1" marker="$2"
  if upload_snapshot "$target" "$BACKUP_DIR/${marker##*/}"; then
    touch "$STATE_DIR/verified-$target" && rm -- "$marker"
  else
    echo "Upload to $target failed, pending: ${marker##*/}"
    return 1
  fi
}

mkdir -p "$STATE_DIR/pending/github" "$STATE_DIR/pending/webdav"
for queued_target in github webdav; do
  for pending_marker in "$STATE_DIR/pending/$queued_target"/vw-*.tar.gz.age; do
    [[ -f "$pending_marker" && ! -L "$pending_marker" ]] || continue
    try_pending_upload "$queued_target" "$pending_marker" || break
  done
done

check_backup_ages() {
  [[ "${VW_EXECUTION_MODE:-}" == systemd ]] || return 0
  local hours="${ALERT_MAX_BACKUP_AGE_HOURS:-}" days="${ALERT_MAX_DRILL_AGE_DAYS:-90}" now timestamp pending_count oldest count=0
  case "$BACKUP_FREQUENCY" in
    weekly) hours="${hours:-192}" ;;
    monthly) hours="${hours:-768}" ;;
    *) hours="${hours:-36}" ;;
  esac
  [[ "$hours" =~ ^[1-9][0-9]{0,4}$ && "$days" =~ ^[1-9][0-9]{0,3}$ ]] || return 0
  now=$(date +%s)
  if [[ -f "$STATE_DIR/verified-$BACKUP_TARGET" ]]; then
    timestamp=$(stat -c %Y "$STATE_DIR/verified-$BACKUP_TARGET")
    if (( now - timestamp > hours * 3600 )); then
      vw_notify failure "Vaultwarden: $BACKUP_TARGET backup verification is overdue." || true
    fi
  else
    vw_notify failure "Vaultwarden: no successful $BACKUP_TARGET verification has been recorded since upgrading." || true
  fi
  touch -a "$STATE_DIR/monitor-start"
  timestamp=$(stat -c %Y "$STATE_DIR/drill-verified" 2>/dev/null || stat -c %Y "$STATE_DIR/monitor-start")
  if (( now - timestamp > days * 86400 )); then
    vw_notify failure "Vaultwarden: an isolated recovery drill is overdue." || true
  fi
  pending_count=$(find "$STATE_DIR/pending" -type f -name 'vw-*.tar.gz.age' -printf '%T@\n')
  oldest=$now
  for timestamp in $pending_count; do
    timestamp=${timestamp%.*}
    count=$((count + 1))
    if (( timestamp < oldest )); then oldest=$timestamp; fi
  done
  if (( count >= 7 || now - oldest > hours * 3600 )); then
    vw_notify failure "Vaultwarden: $count uploads pending, please check connectivity and backup logs." || true
  fi
}
check_backup_ages

vw_perf_stage_end success
vw_perf_stage_begin "manifest_generation"

# Capture sanitized deployment information before stopping the container.
MANIFEST_PLAIN="$TMP_ROOT/deployment-manifest.json"
if ! python3 "$MANIFEST_TOOL" "$CONTAINER" "$MANIFEST_PLAIN"; then FAILURE_REASON="could not create sanitized deployment manifest"; exit 1; fi
vw_perf_stage_end success
# Snapshot the whole /data mount while the app is stopped. All SQLite DB/WAL/SHM
# files and attachments therefore belong to one consistent point in time.
SNAPSHOT_SOURCE="$DATA_DIR"
if [[ "$SNAPSHOT_MODE" == online ]]; then
  echo "Creating an online SQLite snapshot while Vaultwarden is running..."
  SNAPSHOT_SOURCE="$TMP_ROOT/online"
  vw_require_free_space "$TMP_ROOT" "$BACKUP_REQUIRED_BYTES" "在线备份暂存目录" || exit 1
  mkdir "$SNAPSHOT_SOURCE"
  sqlite3 -readonly "$DATA_DIR/db.sqlite3" ".timeout 10000" ".backup '$SNAPSHOT_SOURCE/db.sqlite3'"
  chmod --reference="$DATA_DIR/db.sqlite3" "$SNAPSHOT_SOURCE/db.sqlite3"
  if (( EUID == 0 )); then chown --reference="$DATA_DIR/db.sqlite3" "$SNAPSHOT_SOURCE/db.sqlite3"; fi
else
echo "Stopping Vaultwarden briefly to create a consistent /data snapshot..."
vw_perf_downtime_begin
vw_perf_stage_begin "container_stop"
stop_rc=0
if vw_ensure_target_stopped "$CONTAINER" "$DATA_DIR" 30; then stop_rc=0; else stop_rc=$?; fi
if [[ "${VW_CONTAINER_STOPPED_BY_HELPER:-0}" == 1 ]]; then STOPPED=1; fi
if (( stop_rc != 0 )); then FAILURE_REASON="could not confirm the target container stopped"; exit 1; fi
CONTAINER="$VW_DETECTED_CONTAINER"
vw_perf_stage_end success
fi

vw_perf_stage_begin "sqlite_quick_check"
if command -v sqlite3 >/dev/null 2>&1; then
  SQLITE_RESULT=$(sqlite3 -readonly "$SNAPSHOT_SOURCE/db.sqlite3" 'PRAGMA quick_check;' 2>&1) || { FAILURE_REASON="SQLite quick_check command failed: $SQLITE_RESULT"; echo "ERROR: $FAILURE_REASON"; exit 1; }
  [[ "$SQLITE_RESULT" == "ok" ]] || { FAILURE_REASON="SQLite quick_check failed: $SQLITE_RESULT"; echo "ERROR: $FAILURE_REASON"; exit 1; }
  echo "SQLite quick_check: OK"
  vw_perf_stage_end success "$(stat -c '%s' "$DATA_DIR/db.sqlite3")"
else
  echo "WARNING: sqlite3 command missing; DB quick_check skipped."
  vw_perf_stage_end skipped
fi

vw_perf_stage_begin "snapshot_tar_age"
echo "Creating encrypted complete /data snapshot..."
OUTPUT_CREATED=true
if [[ "$SNAPSHOT_MODE" == online ]]; then
  tar --numeric-owner --exclude='./db.sqlite3' --exclude='./db.sqlite3-*' -czpf - -C "$DATA_DIR" . -C "$SNAPSHOT_SOURCE" db.sqlite3 | age -r "$AGE_RECIPIENT" -o "$OUTPUT"
else
  tar --numeric-owner -czpf - -C "$DATA_DIR" . | age -r "$AGE_RECIPIENT" -o "$OUTPUT"
fi
[[ -s "$OUTPUT" ]] || { FAILURE_REASON="encrypted archive is empty"; exit 1; }
SNAPSHOT_CREATED=true
SIZE_BYTES=$(stat -c '%s' "$OUTPUT")
HEADER=$(head -n 1 "$OUTPUT" 2>/dev/null || true)
[[ "$HEADER" == "age-encryption.org/v1" ]] || { FAILURE_REASON="output is not a valid age file header"; exit 1; }
(cd "$BACKUP_DIR" && sha256sum "$FILENAME" > "$FILENAME.sha256" && sha256sum -c "$FILENAME.sha256") || { FAILURE_REASON="snapshot SHA256 validation failed"; exit 1; }
LOCAL_VERIFIED=true
touch "$STATE_DIR/local-snapshot"
write_result running "encrypted snapshot created and SHA256 verified" || { FAILURE_REASON="could not persist snapshot result state"; exit 1; }
vw_perf_stage_end success "$SIZE_BYTES"

# Start the service immediately after snapshot generation, before Git/network work.
if [[ "$STOPPED" == 1 ]]; then
echo "Encrypted snapshot created. Restarting Vaultwarden before network upload..."
vw_perf_stage_begin "container_start_command"
if ! docker start "$CONTAINER" >/dev/null; then FAILURE_REASON="snapshot made but docker start failed"; vw_perf_stage_end failed; exit 1; fi
STOPPED=0
vw_perf_stage_end success
else
  vw_perf_record_event SERVICE_DOWNTIME 0 aggregate 0
fi

vw_perf_stage_begin "container_health_check_wait"
health_rc=0
if wait_container_healthy "$CONTAINER" 120 2 2; then health_rc=0; else health_rc=$?; fi
vw_perf_stage_end aggregate
if (( health_rc != 0 )); then FAILURE_REASON="container did not pass active health probes after snapshot"; exit 1; fi
SERVICE_RESTORED=true
vw_perf_downtime_end success
vw_perf_stage_begin "local_validation_manifest_checksum"

echo "Vaultwarden is running; continuing offline validation and $UPLOAD_TARGET upload."
echo "Encrypted backup size: $(vw_format_bytes "$SIZE_BYTES")"

# If the original identity was deliberately kept on this host, perform actual
# decrypt + tar + SQLite validation. This is optional: normal scheduled backup
# requires only the public recipient and does not keep the private key online.
if [[ -n "${AGE_IDENTITY_DEFAULT:-}" && -f "$AGE_IDENTITY_DEFAULT" ]]; then
  ID_PUB=$(age-keygen -y "$AGE_IDENTITY_DEFAULT" 2>/dev/null || true)
  if [[ "$ID_PUB" == "$AGE_RECIPIENT" ]]; then
    VALIDATE_REQUIRED_BYTES=$((SOURCE_BYTES + SOURCE_BYTES / 5))
    SHM_TYPE=$(stat -f -c '%T' /dev/shm 2>/dev/null || true)
    SHM_AVAILABLE_BYTES=$(df -PB1 -- /dev/shm 2>/dev/null | awk 'NR==2 {print $4}' || true)
    if [[ "$SHM_TYPE" == tmpfs && "$SHM_AVAILABLE_BYTES" =~ ^[0-9]+$ ]] && (( SHM_AVAILABLE_BYTES >= VALIDATE_REQUIRED_BYTES )); then
      VALIDATE_DIR=$(mktemp -d /dev/shm/vw-backup-validation.XXXXXX)
      chmod 700 "$VALIDATE_DIR"
      if ! age -d -i "$AGE_IDENTITY_DEFAULT" "$OUTPUT" | tar --numeric-owner -xzpf - -C "$VALIDATE_DIR"; then FAILURE_REASON="optional local decrypt/extract validation failed"; exit 1; fi
      [[ -s "$VALIDATE_DIR/db.sqlite3" ]] || { FAILURE_REASON="decrypted backup has no db.sqlite3"; exit 1; }
      SQLITE_RESULT=$(sqlite3 -readonly "$VALIDATE_DIR/db.sqlite3" 'PRAGMA quick_check;' 2>&1) || { FAILURE_REASON="decrypted SQLite quick_check failed: $SQLITE_RESULT"; exit 1; }
      [[ "$SQLITE_RESULT" == "ok" ]] || { FAILURE_REASON="decrypted SQLite quick_check returned: $SQLITE_RESULT"; exit 1; }
      DECRYPT_VERIFIED=true
      touch "$STATE_DIR/decrypt-verified"
      echo "Local age decrypt + tar + SQLite validation on tmpfs: PASS"
      rm -rf -- "$VALIDATE_DIR"
      VALIDATE_DIR=""
    else
      echo "INFO: /dev/shm is not tmpfs or lacks enough free space; optional decrypt validation skipped to avoid writing plaintext to persistent storage."
    fi
  else
    echo "WARNING: AGE_IDENTITY_DEFAULT does not match AGE_RECIPIENT; decrypt validation skipped."
  fi
else
  echo "INFO: age private key is offline/not present; encryption pipeline, age header and SHA256 will be checked. Use menu 'Verify backup' with offline key for a real decryption rehearsal."
fi

# Create separately-encrypted deployment manifest; it contains no secret values.
echo "Encrypting sanitized deployment manifest..."
MANIFEST_CREATED=true
if ! age -r "$AGE_RECIPIENT" -o "$MANIFEST_OUTPUT" "$MANIFEST_PLAIN"; then FAILURE_REASON="deployment manifest encryption failed"; exit 1; fi
[[ -s "$MANIFEST_OUTPUT" ]] || { FAILURE_REASON="encrypted deployment manifest is empty"; exit 1; }
MANIFEST_COMPLETE=true

(cd "$BACKUP_DIR" && sha256sum "$FILENAME" > "$FILENAME.sha256" && sha256sum "$MANIFEST_FILENAME" > "$MANIFEST_FILENAME.sha256")
(cd "$BACKUP_DIR" && sha256sum -c "$FILENAME.sha256" && sha256sum -c "$MANIFEST_FILENAME.sha256")
LOCAL_VERIFIED=true
MANIFEST_VERIFIED=true
python3 "$STORAGE_TOOL" sign "$OUTPUT" && python3 "$STORAGE_TOOL" sign "$MANIFEST_OUTPUT" || { FAILURE_REASON="backup signing failed; local ciphertext retained"; exit 1; }
vw_perf_stage_end success "$SIZE_BYTES"
targets=("$UPLOAD_TARGET")
if [[ "$SECONDARY_TARGET" != none && "$SECONDARY_TARGET" != "$UPLOAD_TARGET" ]]; then
  targets+=("$SECONDARY_TARGET")
fi
for target in "${targets[@]}"; do
  touch "$STATE_DIR/pending/$target/$FILENAME"
done
for target in "${targets[@]}"; do
  if [[ "$target" == github ]]; then
    vw_perf_stage_begin "github_sync_retention_push_verify"
  else
    vw_perf_stage_begin "webdav_upload_readback_verify"
  fi
  if try_pending_upload "$target" "$STATE_DIR/pending/$target/$FILENAME"; then
    if [[ "$target" == github ]]; then
      REMOTE_VERIFIED_GITHUB=true
    else
      REMOTE_VERIFIED_WEBDAV=true
    fi
    [[ "$target" != "$UPLOAD_TARGET" ]] || REMOTE_VERIFIED=true
    vw_perf_stage_end success "$SIZE_BYTES"
  else
    vw_perf_stage_end failed "$SIZE_BYTES"
    if [[ "$target" != "$UPLOAD_TARGET" ]]; then
      vw_notify failure "Vaultwarden: secondary backup to $target is pending ($FILENAME)." || true
    fi
  fi
done
if [[ "$REMOTE_VERIFIED" != true ]]; then
  FAILURE_REASON="primary target $UPLOAD_TARGET was not verified; local ciphertext retained and queued"
  exit 1
fi
if [[ "$UPLOAD_TARGET" == webdav ]]; then
  python3 "$STORAGE_TOOL" prune-local "$BACKUP_DIR" "$RETENTION_DAYS" --webdav --pending "$STATE_DIR/pending" || echo "WARNING: WebDAV local retention cleanup did not complete."
else
  python3 "$STORAGE_TOOL" prune-local "$BACKUP_DIR" "$RETENTION_DAYS" --replica-git "$REPO_DIR" "$(cat "$TMP_ROOT/github-verified-commit")" --pending "$STATE_DIR/pending" || echo "WARNING: GitHub local retention cleanup did not complete."
fi
if [[ "$REMOTE_VERIFIED_WEBDAV" == true && "${WEBDAV_RETENTION_DAYS:-0}" != 0 ]]; then
  python3 "$STORAGE_TOOL" prune-webdav "$BACKUP_DIR" "$WEBDAV_RETENTION_DAYS" "${WEBDAV_MIN_KEEP:-7}" --pending "$STATE_DIR/pending" || echo "WARNING: WebDAV remote retention cleanup did not complete."
fi
# shellcheck disable=SC2034 # 由 vw-common.sh 的 vw_perf_append_row 跨文件读取
VW_PERF_ARTIFACT_BYTES="$SIZE_BYTES"

FINAL_STATUS="success"; FAILURE_REASON=""
SUMMARY="Vaultwarden backup SUCCESS on $(hostname). Container: $CONTAINER. File: $FILENAME. Size: $(vw_format_bytes "$SIZE_BYTES"). $UPLOAD_TARGET remote verified."
echo "$SUMMARY"
echo "Manifest: $MANIFEST_FILENAME"
echo "Finished: $(date '+%F %T %Z')"
echo "===== Backup finished successfully ====="
vw_notify success "$SUMMARY" || true
