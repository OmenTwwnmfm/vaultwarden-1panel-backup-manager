#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/flock" <<'FAKEFLOCK'
#!/usr/bin/env bash
exit 1
FAKEFLOCK
chmod +x "$TMP/bin/flock"

cat > "$TMP/common.sh" <<'FAKECOMMON'
vw_atomic_replace() { mv -- "$1" "$2"; }
FAKECOMMON

run_id="lock-test-$$"
set +e
PATH="$TMP/bin:$PATH" \
VW_RUN_ID="$run_id" \
VW_STATE_DIR="$TMP/state" \
VW_LOG_FILE="$TMP/backup.log" \
VW_LOCK_FILE="$TMP/backup.lock" \
VW_COMMON_LIB="$TMP/common.sh" \
  bash "$ROOT/scripts/vw-backup.sh"
result=$?
set -e

[[ "$result" -eq 75 ]] || { echo "FAIL: expected busy exit 75, got $result" >&2; exit 1; }
grep -Fxq 'STATUS=skipped' "$TMP/state/runs/$run_id.env"
grep -Fxq "RUN_ID=$run_id" "$TMP/state/runs/$run_id.env"
[[ ! -e "$TMP/state/last-result.env" ]] || { echo "FAIL: busy run overwrote the last completed result" >&2; exit 1; }
echo "PASS: lock contention returns 75 and records a run-scoped skipped result"
