#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VW_PERF_FILE="$TMP/performance.tsv"
export VW_PERF_LOCK_FILE="$TMP/performance.lock"
export PYTHONUTF8=1
mkdir -p "$TMP/bin"
cat > "$TMP/bin/flock" <<'FAKEFLOCK'
#!/usr/bin/env bash
exit 0
FAKEFLOCK
cat > "$TMP/bin/python3" <<'FAKEPYTHON'
#!/usr/bin/env bash
exec python "$@"
FAKEPYTHON
chmod +x "$TMP/bin/flock"
chmod +x "$TMP/bin/python3"
PATH="$TMP/bin:$PATH"
export PATH
# shellcheck disable=SC1091
source "$ROOT/scripts/vw-common.sh"
vw_perf_init backup test-backup-run
for stage in container_stop sqlite_quick_check snapshot_tar_age container_start_command container_health_check_wait; do
  vw_perf_stage_begin "$stage"
  sleep 0.01
  vw_perf_stage_end success 1234
done
vw_perf_user_wait_begin
sleep 0.02
vw_perf_user_wait_end
vw_perf_downtime_begin
sleep 0.01
vw_perf_downtime_end aggregate
vw_perf_finish success
python3 - "$VW_PERF_FILE" <<'PY'
import csv, pathlib, sys
p=pathlib.Path(sys.argv[1])
assert p.is_file(), f"performance file missing: {p}"
with p.open(encoding="utf-8", newline="") as f:
    rows=list(csv.DictReader(f, delimiter="\t"))
assert any(r["stage"] == "TOTAL" and r["operation"] == "backup" for r in rows), rows
assert any(r["stage"] == "USER_WAIT" and r["status"] == "informational" for r in rows), rows
assert any(r["stage"] == "SERVICE_DOWNTIME" and r["status"] == "aggregate" for r in rows), rows
expected = {"container_stop", "sqlite_quick_check", "snapshot_tar_age", "container_start_command", "container_health_check_wait"}
assert expected.issubset({r["stage"] for r in rows}), rows
print("PASS: performance initialization, split stages, and total row")
PY
# Assert that production workers actually instrument the stages being tested.
for stage in container_stop sqlite_quick_check snapshot_tar_age container_start_command container_health_check_wait; do
  grep -q "vw_perf_stage_begin \"$stage\"" "$ROOT/scripts/vw-backup.sh" || {
    echo "FAIL: backup worker does not instrument $stage" >&2; exit 1;
  }
done
for stage in restore_container_stop rollback_snapshot_encrypt_validate restore_container_start_command restore_health_check_wait; do
  grep -q "vw_perf_stage_begin \"$stage\"" "$ROOT/scripts/vw-manager.sh" || {
    echo "FAIL: restore manager does not instrument $stage" >&2; exit 1;
  }
done
echo "PASS: backup and restore workers contain the split performance stages"
REPORT=$(python3 "$ROOT/scripts/vw-performance.py" "$VW_PERF_FILE")
for expected in "停止 Vaultwarden 容器" "SQLite quick_check" "完整 /data 快照与 age 加密" "Docker 启动命令" "启动后健康检查等待（汇总）" "主要耗时阶段"; do
  grep -q "$expected" <<<"$REPORT" || { echo "FAIL: report missing label: $expected" >&2; exit 1; }
done
echo "PASS: performance report includes stage breakdown and bottleneck"
