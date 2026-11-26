#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

source "$ROOT/scripts/vw-maintenance.sh"
CONFIG_FILE="$TMP/config"
SCRIPT_DIR="$TMP/installed"
BACKUP_SCRIPT=/usr/local/sbin/vw-backup.sh
RESTORE_SCRIPT=/usr/local/sbin/vw-restore-prepare.sh
MANAGER_SCRIPT=/usr/local/sbin/vw-manager.sh
mkdir -p "$SCRIPT_DIR"
touch "$CONFIG_FILE" "$SCRIPT_DIR/vw-backup.sh"
warn() { printf '%s\n' "$*" >> "$TMP/warnings"; }

# An installed manager lives in /usr/local/sbin and has no sibling run.sh;
# it must not compare its own installed files with a source checkout.
warn_if_helpers_stale
[[ ! -s "$TMP/warnings" ]]

mkdir -p "$TMP/project/scripts"
touch "$TMP/project/run.sh" "$TMP/project/scripts/vw-backup.sh"
SCRIPT_DIR="$TMP/project/scripts"
warn_if_helpers_stale
grep -Fq '后台脚本与当前源码不同' "$TMP/warnings"
grep -Fq 'vw-common.sh' "$TMP/warnings"
grep -Fq 'vw-storage.py' "$TMP/warnings"

echo 'PASS: helper staleness check skips installed mode and covers all installed tools'
