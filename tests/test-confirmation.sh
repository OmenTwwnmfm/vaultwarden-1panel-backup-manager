#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
# Extract just the confirmation function so this test does not start the menu.
sed -n '/^confirm_yes_upper() {/,/^}/p' "$ROOT/scripts/vw-manager.sh" > "$TMP"
# shellcheck disable=SC1090
source "$TMP"
for value in yes YES Yes yEs; do
  if ! printf '%s\n' "$value" | confirm_yes_upper test >/dev/null 2>&1; then
    echo "FAIL: expected '$value' to be accepted" >&2; exit 1
  fi
done
for value in no Y n '' 'YES PLEASE'; do
  if printf '%s\n' "$value" | confirm_yes_upper test >/dev/null 2>&1; then
    echo "FAIL: expected '$value' to be rejected" >&2; exit 1
  fi
done
echo "PASS: confirmation accepts yes in any case and rejects other input"
