#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export VW_PERF_FILE="$TMP/performance.tsv"
export VW_PERF_LOCK_FILE="$TMP/performance.lock"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/flock" <<'FAKEFLOCK'
#!/usr/bin/env bash
exit 0
FAKEFLOCK
chmod +x "$TMP/bin/flock"
PATH="$TMP/bin:$PATH"
export PATH

sed -n '/^read_default() {/,/^}/p' "$ROOT/scripts/vw-manager.sh" > "$TMP/read-default.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/vw-common.sh"
# shellcheck disable=SC1090
source "$TMP/read-default.sh"
vw_perf_init restore read-default-test >/dev/null

value=$(printf '%s\n' '/root/.ssh/vw_github_backup' | read_default 'SSH key path' '/root/.ssh/default' 2>/dev/null)
[[ "$value" == '/root/.ssh/vw_github_backup' ]] || {
  echo "FAIL: prompt instrumentation contaminated the returned value: $value" >&2
  exit 1
}
grep -q $'\trestore\tread-default-test\tUSER_WAIT\t' "$VW_PERF_FILE"
echo "PASS: read_default returns only the entered value while recording USER_WAIT"
