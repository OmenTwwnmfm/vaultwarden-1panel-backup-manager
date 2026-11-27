#!/usr/bin/env bash
# run.sh and the installed vbm launcher each carry their own root-owned tree
# check (the launcher is installed standalone). Keep the two bodies identical
# apart from the root variable and error wording.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
normalize() {
  sed -n "/^$2() {/,/^}/p" "$1" |
    sed -e 's/PROJECT_ROOT/PROJECT_DIR/g' -e 's/echo "错误：[^"]*"/echo MESSAGE/' -e "1s/^$2()/check()/"
}
run_body=$(normalize "$ROOT/run.sh" check_root_owned_tree)
launcher_body=$(normalize "$ROOT/scripts/vbm-launcher.sh" check_project_tree)
[[ -n "$run_body" && -n "$launcher_body" ]] || { echo "FAIL: tree check functions not found" >&2; exit 1; }
if [[ "$run_body" != "$launcher_body" ]]; then
  echo "FAIL: run.sh and vbm-launcher.sh tree checks have drifted:" >&2
  diff <(printf '%s\n' "$run_body") <(printf '%s\n' "$launcher_body") >&2 || true
  exit 1
fi
echo "PASS: run.sh and vbm launcher apply the same root-owned tree check"
