#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
CONFIG_FILE="${VW_CONFIG_FILE:-/etc/vaultwarden-backup.conf}"
COMMON_LIB="${VW_COMMON_LIB:-/usr/local/libexec/vw-common.sh}"
REPORT_DIR="${VW_DIAG_REPORT_DIR:-/var/log/vaultwarden-backup-diagnostics}"
CONFIG_VALID=0
[[ -f "$COMMON_LIB" ]] || { echo "找不到共享安全函数库：$COMMON_LIB" >&2; exit 1; }
# shellcheck disable=SC1090
source "$COMMON_LIB"
mkdir -p "$REPORT_DIR"
chmod 700 "$REPORT_DIR"
STAMP=$(date '+%Y%m%d-%H%M%S')
OUT="$REPORT_DIR/diagnosis-${STAMP}-$$.txt"
# Create and secure the file synchronously before tee starts. Process
# substitution is asynchronous; chmod immediately after `exec > >(tee ...)`
# could race with tee creating the file and fail with ENOENT.
: > "$OUT"
chmod 600 "$OUT"
exec > >(tee -a "$OUT") 2>&1
echo "Vaultwarden Backup Manager diagnostic report"
echo "Generated: $(date '+%F %T %Z')"
echo "Host: $(hostname)"
echo
for cmd in docker age age-keygen git ssh sqlite3 tar gzip sha256sum curl python3 systemctl; do
  if command -v "$cmd" >/dev/null 2>&1; then printf '[OK] %-12s %s\n' "$cmd" "$(command -v "$cmd")"; else printf '[MISSING] %s\n' "$cmd"; fi
done
echo
if [[ -f "$CONFIG_FILE" ]]; then
  if vw_require_secure_config "$CONFIG_FILE"; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    CONFIG_VALID=1
  else
    echo "Configuration: present but unsafe; values were not loaded."
  fi
  if (( CONFIG_VALID == 1 )); then
  echo "Configuration: present (secrets omitted)"
  printf 'Configured container: %s\n' "${CONTAINER:-<unset>}"
  printf 'Configured data path: %s\n' "${DATA_DIR:-<unset>}"
  printf 'GitHub repo: %s\n' "${GITHUB_REPO:-<unset>}"
  printf 'Git branch: %s\n' "${GITHUB_BRANCH:-main}"
  printf 'Backup dir: %s\n' "${BACKUP_DIR:-<unset>}"
  printf 'Local repo dir: %s\n' "${REPO_DIR:-<unset>}"
  printf 'Systemd frequency: %s\n' "${BACKUP_FREQUENCY:-daily}"
  printf 'Systemd schedule: %s\n' "${SYSTEMD_TIME:-*-*-* 05:20:00}"
  printf 'Notification method: %s\n' "${NOTIFY_METHOD:-none}"
  fi
else
  echo "Configuration: MISSING ($CONFIG_FILE)"
fi
if command -v docker >/dev/null 2>&1; then
  echo; echo "Docker containers:"
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  if (( CONFIG_VALID == 1 )); then
    echo; echo "Vaultwarden target discovery:"
    if vw_find_target "${CONTAINER:-}" "${DATA_DIR:-}" true; then
      printf 'Container: %s\nImage: %s\nHealth: %s\nData directory: %s\n' "$VW_DETECTED_CONTAINER" "$VW_DETECTED_IMAGE" "$VW_DETECTED_HEALTH" "$VW_DETECTED_DATA_DIR"
      df -h "$VW_DETECTED_DATA_DIR"
      du -sh "$VW_DETECTED_DATA_DIR"
      [[ -s "$VW_DETECTED_DATA_DIR/db.sqlite3" ]] && stat -c 'SQLite db.sqlite3: %s bytes' "$VW_DETECTED_DATA_DIR/db.sqlite3"
      if command -v sqlite3 >/dev/null 2>&1; then sqlite3 -readonly "$VW_DETECTED_DATA_DIR/db.sqlite3" 'PRAGMA quick_check;' || true; fi
    else
      echo "Target discovery failed; see message above."
    fi
  fi
fi
if command -v systemctl >/dev/null 2>&1; then
  echo; echo "Systemd timer:"
  systemctl status --no-pager vw-backup.timer 2>&1 || true
  systemctl list-timers --all --no-pager | grep -E 'vw-backup|NEXT|LEFT' || true
  echo; echo "Last service result:"
  systemctl show vw-backup.service -p Result -p ExecMainStatus -p ExecMainStartTimestamp -p ExecMainExitTimestamp 2>/dev/null || true
fi
if [[ -f /var/lib/vaultwarden-backup/last-result.env ]]; then
  echo; echo "Last backup result (non-secret fields):"
  cat /var/lib/vaultwarden-backup/last-result.env
fi
if [[ -f /var/log/vaultwarden-backup.log ]]; then
  echo; echo "Recent backup log:"
  tail -n 60 /var/log/vaultwarden-backup.log
fi
echo; echo "Diagnostic report saved: $OUT"

if [[ -f /var/lib/vaultwarden-backup/performance.tsv ]]; then
  echo; echo "Recent performance records (last 20 rows):"
  tail -n 20 /var/lib/vaultwarden-backup/performance.tsv || true
fi
