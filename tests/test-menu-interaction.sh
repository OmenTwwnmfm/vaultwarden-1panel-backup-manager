#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

sed -n '/^choose_backup_name() {/,/^}/p; /^manage_backup_history() {/,/^}/p; /^manage_history() (/,/^)/p; /^render_main_menu() {/,/^}/p; /^main_menu() {/,/^}/p' "$ROOT/scripts/vw-manager.sh" > "$TMP/functions.sh"
source "$TMP/functions.sh"

STORAGE_TOOL=mock-storage-tool
BACKUP_LOCK_FILE="$TMP/vw-backup.lock"
BACKUP_RESULT_FILE="$TMP/last-result.env"
first_archive=vw-20261122-171839.tar.gz.age
second_archive=vw-20261122-160000.tar.gz.age
list_status=0
lock_status=0

load_config() { return 0; }
info() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
ok() { printf '%s\n' "$*"; }
read_default() {
  local prompt="$1" default="$2" value
  printf '%s\n' "$prompt" >> "$TMP/prompts"
  read -r value || true
  printf '%s' "${value:-$default}"
}
confirm_yes_upper() {
  local answer
  printf '%s\n' "$1" >> "$TMP/prompts"
  read -r answer || return 1
  [[ "${answer,,}" == yes ]]
}
pause() {
  printf 'pause\n' >> "$TMP/events"
  read -r _ || true
}
python3() {
  if [[ "$1" == - ]]; then PYTHONUTF8=1 python "$@"; return; fi
  [[ "$1" == "$STORAGE_TOOL" ]] || return 1
  case "$2" in
    list)
      ((list_status == 0)) || return "$list_status"
      printf '%s\n' "$first_archive" "$second_archive"
      ;;
    remote-delete) printf '%s\n' "$3" >> "$TMP/deleted" ;;
    *) return 1 ;;
  esac
}
flock() { return "$lock_status"; }

manage_backup_history <<< $'3\n2\nyes\n' > "$TMP/output"
[[ "$(cat "$TMP/deleted")" == "$second_archive" ]]
grep -Fxq "  1) $first_archive" "$TMP/output"
grep -Fxq "  2) $second_archive" "$TMP/output"
grep -Fxq '输入要删除的备份组编号（0 返回）' "$TMP/prompts"
grep -Fq "删除 $second_archive 及其配套文件" "$TMP/prompts"

manage_backup_history <<< $'3\n0' >/dev/null
manage_backup_history <<< $'3\n' >/dev/null
manage_backup_history <<< $'3\n1\nno' >/dev/null
if manage_backup_history <<< $'3\n3' >/dev/null 2>&1; then
  echo 'FAIL: accepted an out-of-range delete index' >&2
  exit 1
fi
[[ "$(cat "$TMP/deleted")" == "$second_archive" ]]

lock_status=1
if manage_backup_history <<< $'3\n1\nyes' >/dev/null 2>&1; then
  echo 'FAIL: allowed WebDAV deletion during backup' >&2
  exit 1
fi
[[ "$(cat "$TMP/deleted")" == "$second_archive" ]]

list_status=1
if manage_backup_history <<< '3' > "$TMP/output"; then
  echo 'FAIL: treated WebDAV listing failure as success' >&2
  exit 1
fi
[[ ! -s "$TMP/output" ]]

lock_status=0
GITHUB_REPO=mock-repo
GITHUB_BRANCH=main
GITHUB_SSH_KEY=mock-key
BACKUP_DIR="$TMP/local-backups"
mkdir -p "$BACKUP_DIR"
printf 'local backup\n' > "$BACKUP_DIR/$first_archive"
make_ssh_command() { return 0; }
vw_format_bytes() { printf '%s bytes' "$1"; }
mktemp() { command mktemp -d "$TMP/github.XXXXXX"; }
git() {
  case "$1" in
    clone) mkdir -p "$6"; touch "$6/$first_archive" ;;
    -C)
      case "$3" in
        config|add|commit) return 0 ;;
        diff) return 1 ;;
        push) touch "$TMP/push-attempted"; return 1 ;;
      esac
      ;;
  esac
}
if manage_backup_history <<< $'1\n3\n1\nyes' > "$TMP/output" 2>&1; then
  echo 'FAIL: GitHub push failure was treated as success' >&2
  exit 1
fi
[[ -f "$TMP/push-attempted" && -f "$BACKUP_DIR/$first_archive" ]]
grep -Fq 'GitHub 推送失败' "$TMP/output"

VERSION=1.4.8
BACKUP_TARGET=github
SYSTEMD_TIME='*-*-* 05:20:00'
systemctl() { printf 'LoadState=loaded\nActiveState=active\n'; }
printf '%s\n' 'BACKUP_TARGET=webdav' 'STATUS=failed' 'FINISHED_AT=2026-11-22\ 17:18:39\ CST' 'LOCAL_VERIFIED=true' 'REMOTE_VERIFIED=false' 'SERVICE_RESTORED=true' > "$BACKUP_RESULT_FILE"
render_main_menu > "$TMP/output"
[[ "$BACKUP_TARGET" == github ]]
grep -Fq '定时备份目标：GitHub · 自动备份：运行中' "$TMP/output"
grep -Fq '2026-11-22 17:18:39 CST · WebDAV · 失败' "$TMP/output"
grep -Fq '本地校验：通过 · 服务恢复：通过 · 远端核验：未通过' "$TMP/output"

require_root() { return 0; }
require_tty() { return 0; }
clear() { printf 'clear\n' >> "$TMP/events"; }
render_main_menu() { printf 'menu\n' >> "$TMP/events"; }
restore_rehearsal() {
  printf 'result\n' >> "$TMP/events"
  return "$rehearsal_status"
}
warn() { printf 'unexpected input\n' >> "$TMP/events"; }

for rehearsal_status in 0 1; do
  : > "$TMP/events"
  (VBM_SKIP_UPDATE_CHECK=1 main_menu) <<< $'09\n\n00' >/dev/null
  [[ "$(cat "$TMP/events")" == $'clear\nmenu\nresult\npause\nclear\nmenu' ]]
done

echo 'PASS: WebDAV deletes by group index and rehearsal pauses once before clearing the result'
