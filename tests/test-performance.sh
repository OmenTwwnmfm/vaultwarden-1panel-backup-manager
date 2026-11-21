#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VW_PERF_FILE="$TMP/performance.tsv"
# shellcheck disable=SC1091
source "$ROOT/scripts/vw-common.sh"
vw_perf_init backup test-backup-run
vw_perf_stage_begin test_stage
sleep 0.02
vw_perf_stage_end success 1234
vw_perf_finish success
python3 - "$VW_PERF_FILE" <<'PY'
import csv, pathlib, sys
p=pathlib.Path(sys.argv[1])
assert p.is_file(), f"performance file missing: {p}"
with p.open(encoding="utf-8", newline="") as f:
    rows=list(csv.DictReader(f, delimiter="\t"))
assert any(r["stage"] == "test_stage" and r["status"] == "success" for r in rows), rows
assert any(r["stage"] == "TOTAL" and r["operation"] == "backup" for r in rows), rows
print("PASS: performance initialization, stage append, and total row")
PY
