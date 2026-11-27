#!/usr/bin/env bash
# Worker regressions for v1.5.3: online tar retry, GitHub oversize handling
# without endless pending retries, and deduplicated post-run age alerts.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/data"
export PYTHONUTF8=1 VW_TEST_ROOT="$TMP"
VW_TEST_REAL_MKTEMP="$(command -v mktemp)"
export VW_TEST_REAL_MKTEMP
printf 'test database\n' > "$TMP/data/db.sqlite3"
VW_TEST_REAL_TAR="$(command -v tar)"
export VW_TEST_REAL_TAR

cat > "$TMP/common.sh" <<'COMMON'
vw_atomic_replace() { mv -- "$1" "$2"; }
vw_require_secure_config() { return 0; }
vw_save_config() { return 0; }
vw_update_config_values() { return 0; }
vw_find_target() {
  VW_DETECTED_CONTAINER=test-vaultwarden
  VW_DETECTED_DATA_DIR="$DATA_DIR"
  VW_DETECTED_IMAGE=vaultwarden/server:test
  VW_DETECTED_HEALTH=healthy
}
vw_ensure_target_stopped() { VW_CONTAINER_STOPPED_BY_HELPER=1; }
vw_wait_healthy() { return 0; }
vw_perf_init() { VW_PERF_STARTED=0; }
vw_perf_stage_begin() { return 0; }
vw_perf_stage_end() { return 0; }
vw_perf_downtime_begin() { return 0; }
vw_perf_downtime_end() { return 0; }
vw_perf_record_event() { return 0; }
vw_require_free_space() { return 0; }
vw_notify() { printf '%s\n' "$2" >> "$VW_TEST_ROOT/notifications"; }
vw_format_bytes() { printf '%s bytes' "$1"; }
COMMON
cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
[[ "$1" == start ]]
DOCKER
cat > "$TMP/bin/age" <<'AGE'
#!/usr/bin/env bash
[[ "$1" == -r && "$3" == -o ]] || exit 1
printf 'age-encryption.org/v1\n' > "$4"
if [[ $# == 5 ]]; then cat "$5" >> "$4"; else cat >> "$4"; fi
AGE
cat > "$TMP/bin/tar" <<'TAR'
#!/usr/bin/env bash
"$VW_TEST_REAL_TAR" "$@"
rc=$?
count=$(cat "$VW_TEST_ROOT/tar-count" 2>/dev/null || echo 0)
if (( count < ${VW_TEST_TAR_FAILS:-0} )); then
  echo $((count + 1)) > "$VW_TEST_ROOT/tar-count"
  echo "tar: ./attachments: file changed as we read it" >&2
  exit 1
fi
exit "$rc"
TAR
cat > "$TMP/bin/sqlite3" <<'SQLITE'
#!/usr/bin/env bash
if [[ "${3:-}" == '.timeout 10000' ]]; then
  destination="${4#.backup \'}"
  destination="${destination%\'}"
  cp -- "$2" "$destination"
  exit
fi
printf 'ok\n'
SQLITE
cat > "$TMP/bin/flock" <<'FLOCK'
#!/usr/bin/env bash
exit 0
FLOCK
VW_TEST_REAL_PYTHON="$(command -v python || command -v python3)"
export VW_TEST_REAL_PYTHON
cat > "$TMP/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
case "$1" in
  *vw-storage.py)
    case "$2" in
      check-signing|verify-signature|prune-local) ;;
      sign) printf 'mock signature\n' > "$3.sha256.sig" ;;
      upload) [[ "${VW_TEST_UPLOAD_FAIL:-0}" == 0 ]] || exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  *vw-manifest.py) printf '{}\n' > "$3" ;;
  *) exec "$VW_TEST_REAL_PYTHON" "$@" ;;
esac
PYTHON
cat > "$TMP/bin/mktemp" <<'MKTEMP'
#!/usr/bin/env bash
if [[ "${2:-}" == /var/tmp/vw-backup.* ]]; then
  exec "$VW_TEST_REAL_MKTEMP" -d "$VW_TEST_ROOT/work.XXXXXX"
fi
exec "$VW_TEST_REAL_MKTEMP" "$@"
MKTEMP
chmod +x "$TMP/bin/"*
PATH="$TMP/bin:$PATH"
export PATH

write_config() {
  local name="$1"; shift
  mkdir -p "$TMP/$name/backups" "$TMP/$name/state"
  {
    printf 'CONTAINER=test-vaultwarden\nAGE_RECIPIENT=age1test\nRETENTION_DAYS=30\nMIN_FREE_MB=0\n'
    printf 'DATA_DIR=%q\nBACKUP_DIR=%q\nREPO_DIR=%q\n' "$TMP/data" "$TMP/$name/backups" "$TMP/$name/repo"
    printf '%s\n' "$@"
  } > "$TMP/$name/config"
}

run_worker() {
  local name="$1" target="$2" run_id="$3" result=0
  VW_CONFIG_FILE="$TMP/$name/config" VW_COMMON_LIB="$TMP/common.sh" \
  VW_MANIFEST_TOOL="$ROOT/scripts/vw-manifest.py" VW_STATE_DIR="$TMP/$name/state" \
  VW_LOG_FILE="$TMP/$name/log" VW_LOCK_FILE="$TMP/operation.lock" \
  VW_RUN_ID="$run_id" bash "$ROOT/scripts/vw-backup.sh" "$target" || result=$?
  return "$result"
}

fail() { echo "FAIL: $*" >&2; [[ -z "${LOG:-}" || ! -f "$LOG" ]] || cat "$LOG" >&2; exit 1; }

# 1. Online mode: one "file changed" from tar is retried and succeeds.
write_config online-retry 'SNAPSHOT_MODE=online'
LOG="$TMP/online-retry/log"
rm -f "$TMP/tar-count"
VW_TEST_TAR_FAILS=1 run_worker online-retry webdav online-retry || fail "online retry should succeed"
grep -Fq 'retrying once' "$LOG" || fail "online retry was not logged"
grep -Fxq 'STATUS=success' "$TMP/online-retry/state/last-result.env" || fail "online retry result is not success"

# 2. Online mode: tar keeps reporting changes -> fails with an actionable reason.
write_config online-fail 'SNAPSHOT_MODE=online'
LOG="$TMP/online-fail/log"
rm -f "$TMP/tar-count"
if VW_TEST_TAR_FAILS=5 run_worker online-fail webdav online-fail; then fail "online tar failure was accepted"; fi
grep -Fxq 'STATUS=failed' "$TMP/online-fail/state/last-result.env" || fail "online failure not recorded"
grep -Fq 'SNAPSHOT_MODE=stop' "$TMP/online-fail/state/last-result.env" || fail "online failure reason does not recommend stop mode"
[[ -z "$(find "$TMP/online-fail/backups" -name 'vw-*.tar.gz.age' -print)" ]] || fail "incomplete online archive was kept"
rm -f "$TMP/tar-count"

# 3. GitHub primary: an archive larger than MAX_FILE_MIB is never queued for retry.
write_config oversize 'BACKUP_TARGET=github' 'MAX_FILE_MIB=1' 'GITHUB_BRANCH=main' \
  "GITHUB_REPO=git@github.com:example/backups.git" "GITHUB_SSH_KEY=$TMP/oversize/key"
LOG="$TMP/oversize/log"
mkdir -p "$TMP/oversize/repo/.git"
: > "$TMP/oversize/key"
head -c $((1536 * 1024)) /dev/urandom > "$TMP/data/attachment.bin"
if run_worker oversize github oversize; then fail "oversize GitHub upload was accepted"; fi
rm -f "$TMP/data/attachment.bin"
grep -Fq 'single-file' "$TMP/oversize/state/last-result.env" || fail "oversize reason missing"
[[ -z "$(find "$TMP/oversize/state/pending" -type f -print)" ]] || fail "oversize backup stayed in the retry queue"
compgen -G "$TMP/oversize/state/rejected/github/vw-*.tar.gz.age" >/dev/null || fail "oversize backup was not recorded as rejected"
compgen -G "$TMP/oversize/backups/vw-*.tar.gz.age" >/dev/null || fail "local ciphertext was not retained"

# 4. systemd age alerts run after the result and are sent once per 24 hours.
write_config alerts 'BACKUP_TARGET=webdav'
LOG="$TMP/alerts/log"
: > "$TMP/notifications"
touch -d '3 days ago' "$TMP/alerts/state/verified-webdav"
export VW_EXECUTION_MODE=systemd
if VW_TEST_UPLOAD_FAIL=1 run_worker alerts webdav alerts-1; then fail "failing upload succeeded"; fi
[[ "$(grep -c 'verification is overdue' "$TMP/notifications")" == 1 ]] || fail "overdue alert was not sent once"
sleep 1
if VW_TEST_UPLOAD_FAIL=1 run_worker alerts webdav alerts-2; then fail "failing upload succeeded"; fi
[[ "$(grep -c 'verification is overdue' "$TMP/notifications")" == 1 ]] || fail "repeated overdue alert was not suppressed"
sleep 1
run_worker alerts webdav alerts-3 || fail "recovery run failed"
[[ "$(grep -c 'verification is overdue' "$TMP/notifications")" == 1 ]] || fail "successful run reported itself as overdue"
[[ ! -e "$TMP/alerts/state/alerts/backup-overdue-webdav" ]] || fail "recovered alert was not re-armed"
grep -Fq 'INFO: alert already sent within the last 24 hours' "$TMP/alerts/log" || fail "suppression was not logged"
unset VW_EXECUTION_MODE

echo "PASS: online tar retry, GitHub oversize rejection, and deduplicated post-run alerts"
