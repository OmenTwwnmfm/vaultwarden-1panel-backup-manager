#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/data"
export PYTHONUTF8=1 VW_TEST_ROOT="$TMP"
printf 'test database\n' > "$TMP/data/db.sqlite3"
cat > "$TMP/common.sh" <<'COMMON'
vw_atomic_replace() { mv -- "$1" "$2"; }
vw_require_secure_config() { return 0; }
vw_save_config() { return 0; }
vw_find_target() {
  VW_DETECTED_CONTAINER=test-vaultwarden
  VW_DETECTED_DATA_DIR="$DATA_DIR"
  VW_DETECTED_IMAGE=vaultwarden/server:test
  VW_DETECTED_HEALTH=healthy
}
vw_ensure_target_stopped() {
  VW_CONTAINER_STOPPED_BY_HELPER=1
  printf 'stop\n' >> "$VW_TEST_ROOT/order"
}
vw_wait_healthy() { printf 'healthy\n' >> "$VW_TEST_ROOT/order"; }
vw_perf_init() { VW_PERF_STARTED=0; }
vw_perf_stage_begin() { return 0; }
vw_perf_stage_end() { return 0; }
vw_perf_downtime_begin() { return 0; }
vw_perf_downtime_end() { return 0; }
vw_perf_record_event() { return 0; }
vw_require_free_space() { return 0; }
vw_notify() { return 0; }
vw_format_bytes() { printf '%s bytes' "$1"; }
COMMON
cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
[[ "$1" == start ]] || exit 1
printf 'start\n' >> "$VW_TEST_ROOT/order"
DOCKER
cat > "$TMP/bin/age" <<'AGE'
#!/usr/bin/env bash
[[ "$1" == -r && "$3" == -o ]] || exit 1
printf 'age-encryption.org/v1\n' > "$4"
if [[ $# == 5 ]]; then cat "$5" >> "$4"; else cat >> "$4"; fi
AGE
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
cat > "$TMP/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
case "$1" in
  *vw-storage.py)
    case "$2" in
      check-signing|verify-signature) ;;
      sign) printf 'mock signature\n' > "$3.sha256.sig" ;;
      upload)
        [[ -s "$3" && -s "$3.sha256" ]] || exit 1
        printf 'upload\n' >> "$VW_TEST_ROOT/order"
        [[ "${VW_TEST_UPLOAD_FAIL:-0}" == 0 ]] || exit 1
        ;;
      prune-local) ;;
      *) exit 1 ;;
    esac
    ;;
  *vw-manifest.py) printf '{}\n' > "$3" ;;
  *) exec python "$@" ;;
esac
PYTHON
cat > "$TMP/bin/mktemp" <<'MKTEMP'
#!/usr/bin/env bash
if [[ "${2:-}" == /var/tmp/vw-backup.* ]]; then
  exec /usr/bin/mktemp -d "$VW_TEST_ROOT/work.XXXXXX"
fi
exec /usr/bin/mktemp "$@"
MKTEMP
chmod +x "$TMP/bin/"*
PATH="$TMP/bin:$PATH"
export PATH
for outcome in success failed online dual; do
  mkdir -p "$TMP/$outcome/backups" "$TMP/$outcome/state"
  : > "$TMP/order"
  {
    printf 'CONTAINER=test-vaultwarden\nAGE_RECIPIENT=age1test\nRETENTION_DAYS=30\nMIN_FREE_MB=0\nBACKUP_TARGET=github\n'
    printf 'DATA_DIR=%q\nBACKUP_DIR=%q\nREPO_DIR=%q\n' "$TMP/data" "$TMP/$outcome/backups" "$TMP/repo"
  } > "$TMP/config"
  export VW_TEST_UPLOAD_FAIL=0
  [[ "$outcome" == success ]] || VW_TEST_UPLOAD_FAIL=1
  primary=webdav
  expected_status="$outcome"
  case "$outcome" in
    online)
      printf 'SNAPSHOT_MODE=online\n' >> "$TMP/config"
      VW_TEST_UPLOAD_FAIL=0
      expected_status=success
      ;;
    dual)
      dual_repo="$TMP/dual/git-worktree"
      dual_remote="$TMP/dual/remote.git"
      git init --quiet --bare --initial-branch=main "$dual_remote"
      git init --quiet --initial-branch=main "$dual_repo"
      git -C "$dual_repo" config user.name Tester
      git -C "$dual_repo" config user.email test@example.invalid
      git -C "$dual_repo" remote add origin "$dual_remote"
      touch "$TMP/dual/deploy-key"
      dual_origin=$(git -C "$dual_repo" remote get-url origin)
      printf 'GITHUB_REPO=%q\nREPO_DIR=%q\nGITHUB_SSH_KEY=%q\nGITHUB_BRANCH=main\nSECONDARY_TARGET=webdav\n' "$dual_origin" "$dual_repo" "$TMP/dual/deploy-key" >> "$TMP/config"
      primary=github
      expected_status=success
      ;;
  esac
  result=0
  VW_CONFIG_FILE="$TMP/config" VW_COMMON_LIB="$TMP/common.sh" \
  VW_MANIFEST_TOOL="$ROOT/scripts/vw-manifest.py" VW_STATE_DIR="$TMP/$outcome/state" \
  VW_LOG_FILE="$TMP/$outcome/log" VW_LOCK_FILE="$TMP/operation.lock" \
  VW_RUN_ID="webdav-$outcome" bash "$ROOT/scripts/vw-backup.sh" "$primary" || result=$?
  [[ "$expected_status" != success || "$result" == 0 ]] || { cat "$TMP/$outcome/log"; exit 1; }
  [[ "$expected_status" != failed || "$result" != 0 ]] || exit 1
  grep -Fxq "STATUS=$expected_status" "$TMP/$outcome/state/last-result.env"
  grep -Fxq "BACKUP_TARGET=$primary" "$TMP/$outcome/state/last-result.env"
  grep -Fxq 'SERVICE_RESTORED=true' "$TMP/$outcome/state/last-result.env"
  expected_remote=true
  [[ "$expected_status" == success ]] || expected_remote=false
  grep -Fxq "REMOTE_VERIFIED=$expected_remote" "$TMP/$outcome/state/last-result.env"
  [[ "$(find "$TMP/$outcome/backups" -type f | wc -l)" -eq 6 ]]
  if [[ "$outcome" == online ]]; then
    [[ "$(tr '\n' ' ' < "$TMP/order")" == 'healthy upload ' ]]
  else
    [[ "$(tr '\n' ' ' < "$TMP/order")" == 'stop start healthy upload ' ]]
  fi
  if [[ "$outcome" == failed || "$outcome" == dual ]]; then
    compgen -G "$TMP/$outcome/state/pending/webdav/vw-*.tar.gz.age" >/dev/null
  else
    [[ -z "$(find "$TMP/$outcome/state/pending" -type f -print)" ]]
  fi
  if [[ "$outcome" == dual ]]; then
    grep -Fxq 'REMOTE_VERIFIED_GITHUB=true' "$TMP/dual/state/last-result.env"
    grep -Fxq 'REMOTE_VERIFIED_WEBDAV=false' "$TMP/dual/state/last-result.env"
    [[ "$(git -C "$dual_remote" ls-tree --name-only main | wc -l)" -eq 6 ]]
    sleep 1
    : > "$TMP/order"
    VW_TEST_UPLOAD_FAIL=0 VW_CONFIG_FILE="$TMP/config" VW_COMMON_LIB="$TMP/common.sh" \
    VW_MANIFEST_TOOL="$ROOT/scripts/vw-manifest.py" VW_STATE_DIR="$TMP/dual/state" \
    VW_LOG_FILE="$TMP/dual/retry.log" VW_LOCK_FILE="$TMP/operation.lock" \
    VW_RUN_ID=dual-retry bash "$ROOT/scripts/vw-backup.sh" github || { cat "$TMP/dual/retry.log"; exit 1; }
    [[ "$(tr '\n' ' ' < "$TMP/order")" == 'upload stop start healthy upload ' ]]
    [[ -z "$(find "$TMP/dual/state/pending" -type f -print)" ]]
  fi
done
echo "PASS: WebDAV worker needs no GitHub credentials, restores service before upload, and retains snapshots on failure"
