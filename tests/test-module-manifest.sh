#!/usr/bin/env bash
# The manager sources, installs (menu [22]) and staleness-checks the modules
# listed in MANAGER_MODULES. Every scripts/manager-*.sh must be on that list.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$ROOT/scripts/vw-manager.sh"
line=$(grep -E '^MANAGER_MODULES=\(' "$MANAGER") || { echo "FAIL: MANAGER_MODULES not found" >&2; exit 1; }
eval "$line"
listed=$(printf '%s\n' ${MANAGER_MODULES[@]+"${MANAGER_MODULES[@]}"} | sort)
present=$(find "$ROOT/scripts" -maxdepth 1 -type f -name 'manager-*.sh' -printf '%f\n' | sort)
if [[ "$listed" != "$present" ]]; then
  echo "FAIL: MANAGER_MODULES does not match scripts/manager-*.sh" >&2
  diff <(printf '%s\n' "$listed") <(printf '%s\n' "$present") >&2 || true
  exit 1
fi
grep -Fq 'for module in "${MANAGER_MODULES[@]}"; do' <(sed -n '/^install_helper_scripts() {/,/^}/p' "$MANAGER") || {
  echo "FAIL: install_helper_scripts does not install MANAGER_MODULES" >&2; exit 1;
}
grep -Fq 'MANAGER_MODULES[@]' <(sed -n '/^warn_if_helpers_stale() {/,/^}/p' "$ROOT/scripts/vw-maintenance.sh") || {
  echo "FAIL: warn_if_helpers_stale does not check MANAGER_MODULES" >&2; exit 1;
}
if grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$MANAGER" "$ROOT"/scripts/manager-*.sh 2>/dev/null | grep -v 'vbm_source_trusted' | grep -Fv 'source "$file"' | grep -Fv 'source "$CONFIG_FILE"'; then
  echo "FAIL: manager code sources files without vbm_source_trusted" >&2; exit 1
fi
echo "PASS: manager modules are trusted-sourced, installed and staleness-checked"
