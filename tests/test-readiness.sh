#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VW_PERF_FILE="$TMP/performance.tsv"
export VW_PERF_LOCK_FILE="$TMP/performance.lock"
export PYTHONUTF8=1
export VW_TEST_MODE_FILE="$TMP/mode"
export VW_TEST_PROBE_COUNT="$TMP/probes"
mkdir -p "$TMP/bin"
printf 'active\n' > "$VW_TEST_MODE_FILE"
printf '0\n' > "$VW_TEST_PROBE_COUNT"

# Fake Docker executable: this lets the real `timeout` command wrap docker exec.
cat > "$TMP/bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
mode=$(cat "$VW_TEST_MODE_FILE")
case "${1:-}" in
  inspect)
    template="${3:-}"
    case "$template" in
      *'.Config.Healthcheck.Test'*)
        if [[ "$mode" == active ]]; then printf '["CMD","/healthcheck.sh"]\n'; else printf '["CMD-SHELL","custom-healthcheck"]\n'; fi
        ;;
      *'.State.Status'*) printf 'running\n' ;;
      *'.State.Health'*)
        if [[ "$mode" == active ]]; then printf 'starting\n'; else printf 'healthy\n'; fi
        ;;
      *) echo "unexpected inspect template: $template" >&2; exit 2 ;;
    esac
    ;;
  exec)
    [[ "${3:-}" == "/healthcheck.sh" ]] || exit 2
    n=$(cat "$VW_TEST_PROBE_COUNT")
    echo "$((n + 1))" > "$VW_TEST_PROBE_COUNT"
    exit 0
    ;;
  *) echo "unexpected docker command: $*" >&2; exit 2 ;;
esac
FAKEDOCKER
cat > "$TMP/bin/flock" <<'FAKEFLOCK'
#!/usr/bin/env bash
exit 0
FAKEFLOCK
VW_TEST_REAL_PYTHON="$(command -v python || command -v python3)"
export VW_TEST_REAL_PYTHON
cat > "$TMP/bin/python3" <<'FAKEPYTHON'
#!/usr/bin/env bash
exec "$VW_TEST_REAL_PYTHON" "$@"
FAKEPYTHON
chmod +x "$TMP/bin/docker"
chmod +x "$TMP/bin/flock"
chmod +x "$TMP/bin/python3"
PATH="$TMP/bin:$PATH"
export PATH

SLEEPS=0
sleep() { SLEEPS=$((SLEEPS + 1)); :; }
# shellcheck disable=SC1091
source "$ROOT/scripts/vw-common.sh"

vw_perf_init backup readiness-test-run
vw_perf_stage_begin container_health_check_wait
if vw_wait_healthy test-vaultwarden 120 2 2; then
  vw_perf_stage_end aggregate
else
  vw_perf_stage_end aggregate
  echo "FAIL: active readiness probe did not pass" >&2
  exit 1
fi
vw_perf_finish success

PROBES=$(cat "$VW_TEST_PROBE_COUNT")
[[ "$PROBES" -eq 2 ]] || { echo "FAIL: expected exactly two active probes, got $PROBES" >&2; exit 1; }
[[ "$SLEEPS" -eq 1 ]] || { echo "FAIL: expected one 2-second interval between probes, got $SLEEPS" >&2; exit 1; }

# Non-standard Docker healthchecks keep the native polling compatibility path.
printf 'fallback\n' > "$VW_TEST_MODE_FILE"
VW_PERF_STARTED=0
if ! vw_wait_healthy test-vaultwarden 10 2 2; then
  echo "FAIL: native healthcheck fallback did not accept healthy state" >&2
  exit 1
fi

python3 - "$VW_PERF_FILE" "$ROOT/scripts/vw-performance.py" <<'PY'
import csv
import subprocess
import sys
from pathlib import Path

rows = list(csv.DictReader(Path(sys.argv[1]).open(encoding="utf-8"), delimiter="\t"))
by_stage = {r["stage"]: r for r in rows}
for stage in (
    "readiness_probe_first_success",
    "readiness_probe_confirmation",
    "docker_native_health_observation",
    "container_health_check_wait",
    "TOTAL",
):
    assert stage in by_stage, f"missing performance stage: {stage}; got {list(by_stage)}"
assert by_stage["readiness_probe_first_success"]["status"] == "success"
assert by_stage["readiness_probe_confirmation"]["status"] == "success"
assert by_stage["docker_native_health_observation"]["status"] == "success"
assert by_stage["container_health_check_wait"]["status"] == "aggregate"
assert by_stage["TOTAL"]["status"] == "success"
report = subprocess.check_output([sys.executable, sys.argv[2], sys.argv[1]], text=True)
assert "首次 Vaultwarden /alive 主动探测" in report
assert "第二次主动探测确认" in report
assert "启动后健康检查等待（汇总）" not in report, "aggregate row must not be double-counted in summary"
print("PASS: active probe succeeds twice while Docker native health remains 'starting'.")
print("PASS: non-standard healthcheck falls back to Docker native status polling.")
print("PASS: readiness metrics are recorded and aggregate rows are excluded from stage summary.")
PY

echo "PASS: readiness probe does not wait for Docker's 60-second native healthcheck interval"
