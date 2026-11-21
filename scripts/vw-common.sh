#!/usr/bin/env bash
# Shared helpers for Vaultwarden 1Panel Backup Manager.
set -Eeuo pipefail

vw_error() { printf '[错误] %s\n' "$*" >&2; }
vw_info()  { printf '[信息] %s\n' "$*"; }
vw_ok()    { printf '[完成] %s\n' "$*"; }

# Exports: VW_DETECTED_CONTAINER, VW_DETECTED_IMAGE, VW_DETECTED_STATUS,
# VW_DETECTED_DATA_DIR, VW_DETECTED_HEALTH.
vw_find_target() {
  local preferred_container="${1:-}" preferred_data_dir="${2:-}" require_running="${3:-true}"
  local id name image status source canonical lower health
  local -a names=() images=() statuses=() sources=() healths=() path_matches=()
  command -v docker >/dev/null 2>&1 || { vw_error '找不到 docker 命令。'; return 1; }
  mapfile -t ids < <(docker ps -aq)
  ((${#ids[@]} > 0)) || { vw_error 'Docker 中没有任何容器。'; return 1; }
  for id in "${ids[@]}"; do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##') || continue
    image=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null) || continue
    status=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null) || continue
    lower="${name,,} ${image,,}"
    [[ "$lower" == *vaultwarden* || "$lower" == *bitwarden* ]] || continue
    [[ "$require_running" != true || "$status" == running ]] || continue
    source=$(docker inspect "$id" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d')
    [[ -n "$source" && "$source" != *$'\n'* ]] || continue
    [[ -d "$source" && -s "$source/db.sqlite3" ]] || continue
    canonical=$(readlink -f -- "$source" 2>/dev/null) || continue
    case "$canonical" in /|/var|/var/lib|/var/lib/docker|/opt|/root|/home|/etc|/usr) continue ;; esac
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$id" 2>/dev/null || echo unknown)
    names+=("$name"); images+=("$image"); statuses+=("$status"); sources+=("$canonical"); healths+=("$health")
  done
  ((${#names[@]} > 0)) || { vw_error '未发现正在运行且挂载 /data、包含非空 db.sqlite3 的 Vaultwarden 容器。'; return 1; }

  local chosen=-1 i preferred_data_canonical=""
  if [[ -n "$preferred_data_dir" ]]; then
    [[ -d "$preferred_data_dir" ]] || { vw_error "配置中的数据目录不存在：$preferred_data_dir。请通过管理器重新检测。"; return 2; }
    preferred_data_canonical=$(readlink -f -- "$preferred_data_dir") || return 1
    for i in "${!names[@]}"; do [[ "${sources[$i]}" == "$preferred_data_canonical" ]] && path_matches+=("$i"); done
    if ((${#path_matches[@]} == 1)); then chosen=${path_matches[0]}
    elif ((${#path_matches[@]} > 1)); then vw_error '多个 Vaultwarden 容器共用已配置数据目录，无法安全自动选择。'; return 2
    else
      vw_error "没有容器挂载已配置的数据目录 $preferred_data_canonical。为避免误备份新实例，已停止。"
      for i in "${!names[@]}"; do printf '  - %s | %s | %s | %s\n' "${names[$i]}" "${images[$i]}" "${statuses[$i]}" "${sources[$i]}" >&2; done
      return 2
    fi
  else
    if [[ -n "$preferred_container" ]]; then
      for i in "${!names[@]}"; do [[ "${names[$i]}" == "$preferred_container" ]] && chosen=$i; done
    fi
    if ((chosen < 0)); then
      if ((${#names[@]} == 1)); then chosen=0
      else
        vw_error '发现多个有效 Vaultwarden 容器，请在交互式向导中选择目标。'
        for i in "${!names[@]}"; do printf '  - %s | %s | %s | /data=%s\n' "${names[$i]}" "${images[$i]}" "${statuses[$i]}" "${sources[$i]}" >&2; done
        return 2
      fi
    fi
  fi
  VW_DETECTED_CONTAINER="${names[$chosen]}"; VW_DETECTED_IMAGE="${images[$chosen]}"; VW_DETECTED_STATUS="${statuses[$chosen]}"; VW_DETECTED_DATA_DIR="${sources[$chosen]}"; VW_DETECTED_HEALTH="${healths[$chosen]}"
  export VW_DETECTED_CONTAINER VW_DETECTED_IMAGE VW_DETECTED_STATUS VW_DETECTED_DATA_DIR VW_DETECTED_HEALTH
}

vw_save_config() {
  local tmp var
  [[ -n "${CONFIG_FILE:-}" ]] || return 1
  tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
  {
    for var in CONTAINER DATA_DIR AGE_RECIPIENT GITHUB_REPO GITHUB_BRANCH GITHUB_SSH_KEY BACKUP_DIR REPO_DIR RETENTION_DAYS MAX_FILE_MIB AGE_IDENTITY_DEFAULT SYSTEMD_TIME BACKUP_FREQUENCY MIN_FREE_MB GIT_PUSH_RETRIES GIT_RETRY_DELAY NOTIFY_METHOD TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID NTFY_URL NTFY_TOKEN WEBHOOK_URL NOTIFY_ON_SUCCESS NOTIFY_ON_FAILURE; do
      printf '%s=%q\n' "$var" "${!var-}"
    done
  } > "$tmp"
  chmod 600 "$tmp"; chown root:root "$tmp" 2>/dev/null || true; mv -f -- "$tmp" "$CONFIG_FILE"
}


vw_wait_healthy() {
  local container="$1" attempts="${2:-30}" delay="${3:-2}" i state health
  for ((i=1; i<=attempts; i++)); do
    state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo unknown)
    [[ "$state" == running ]] || { sleep "$delay"; continue; }
    [[ "$health" == unhealthy || "$health" == starting ]] && { sleep "$delay"; continue; }
    return 0
  done
  vw_error "容器未能达到 running/healthy：$container（state=$state health=$health）"
  return 1
}

vw_format_bytes() {
  local bytes="${1:-0}"
  awk -v n="$bytes" 'BEGIN { if (n >= 1073741824) printf "%.2f GiB (%s bytes)", n/1073741824, n; else if (n >= 1048576) printf "%.2f MiB (%s bytes)", n/1048576, n; else if (n >= 1024) printf "%.2f KiB (%.2f MiB; %s bytes)", n/1024, n/1048576, n; else printf "%s bytes (%.2f KiB)", n, n/1024; }'
}

vw_notify() {
  local event="${1:-info}" message="${2:-Vaultwarden backup event}" config="${CONFIG_FILE:-/etc/vaultwarden-backup.conf}"
  [[ -f "$config" ]] || return 0
  # Notification errors must never change backup/restore exit status.
  python3 - "$config" "$event" "$message" <<'PY' || true
import os, sys, urllib.request, urllib.parse, json
cfg_path, event, message = sys.argv[1:4]
# The config is root-owned mode 0600 and contains shell-escaped assignments.
# Source it in a child bash and export only notification variables.
keys = ["NOTIFY_METHOD", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "NTFY_URL", "NTFY_TOKEN", "WEBHOOK_URL", "NOTIFY_ON_SUCCESS", "NOTIFY_ON_FAILURE"]
cmd = 'set -a; . "$1"; for k in ' + ' '.join(keys) + '; do printf "%s=%s\\n" "$k" "${!k-}"; done'
import subprocess
p = subprocess.run(["bash", "-c", cmd, "notify-env", cfg_path], capture_output=True, text=True)
env = {}
for line in p.stdout.splitlines():
    if "=" in line:
        k, v = line.split("=", 1); env[k] = v
method = env.get("NOTIFY_METHOD", "none").lower()
if method in ("", "none", "off"):
    sys.exit(0)
if event == "success" and env.get("NOTIFY_ON_SUCCESS", "true").lower() not in ("1", "true", "yes"):
    sys.exit(0)
if event != "success" and env.get("NOTIFY_ON_FAILURE", "true").lower() not in ("1", "true", "yes"):
    sys.exit(0)
try:
    if method == "telegram":
        token, chat = env.get("TELEGRAM_BOT_TOKEN", ""), env.get("TELEGRAM_CHAT_ID", "")
        if not token or not chat: raise RuntimeError("Telegram token/chat id not configured")
        url = "https://api.telegram.org/bot" + token + "/sendMessage"
        data = urllib.parse.urlencode({"chat_id": chat, "text": message}).encode()
        req = urllib.request.Request(url, data=data, method="POST")
    elif method == "ntfy":
        url, token = env.get("NTFY_URL", ""), env.get("NTFY_TOKEN", "")
        if not url: raise RuntimeError("ntfy URL not configured")
        headers = {"Title": "Vaultwarden Backup", "Priority": "high" if event != "success" else "default"}
        if token: headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(url, data=message.encode(), headers=headers, method="POST")
    elif method == "webhook":
        url = env.get("WEBHOOK_URL", "")
        if not url: raise RuntimeError("Webhook URL not configured")
        data = json.dumps({"project":"Vaultwarden Backup Manager", "event":event, "message":message}, ensure_ascii=False).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type":"application/json"}, method="POST")
    else:
        raise RuntimeError("Unknown notification method: " + method)
    with urllib.request.urlopen(req, timeout=15) as response:
        if response.status < 200 or response.status >= 300: raise RuntimeError("HTTP status " + str(response.status))
except Exception as exc:
    print("[WARN] Notification failed (backup status unchanged):", type(exc).__name__, file=sys.stderr)
    sys.exit(0)
PY
}


# ---- Performance metrics -------------------------------------------------
# TSV format: timestamp, operation, run_id, stage, duration_ms, status, bytes
VW_PERF_FILE_DEFAULT="/var/lib/vaultwarden-backup/performance.tsv"

vw_perf_now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null || true)
  if [[ "$ns" =~ ^[0-9]+$ ]]; then
    printf '%s' "$((ns / 1000000))"
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}

vw_perf_init() {
  local operation="$1" run_id="$2" file="${VW_PERF_FILE:-$VW_PERF_FILE_DEFAULT}"
  mkdir -p "$(dirname "$file")" /run/lock
  touch "$file"
  chmod 600 "$file"
  if [[ ! -s "$file" ]]; then
    printf 'timestamp\toperation\trun_id\tstage\tduration_ms\tstatus\tbytes\n' >> "$file"
  fi
  VW_PERF_FILE="$file"
  VW_PERF_OPERATION="$operation"
  VW_PERF_RUN_ID="$run_id"
  VW_PERF_TOTAL_START_MS=$(vw_perf_now_ms)
  VW_PERF_STAGE_START_MS=""
  VW_PERF_CURRENT_STAGE=""
  VW_PERF_STARTED=1
  VW_PERF_FINISHED=0
  export VW_PERF_FILE VW_PERF_OPERATION VW_PERF_RUN_ID VW_PERF_TOTAL_START_MS VW_PERF_STARTED VW_PERF_FINISHED
}

vw_perf_append_row() {
  local stage="$1" duration_ms="$2" status="$3" bytes="${4:-0}"
  local lock_file="/run/lock/vaultwarden-performance.lock"
  mkdir -p /run/lock "$(dirname "${VW_PERF_FILE:-$VW_PERF_FILE_DEFAULT}")"
  exec 7>"$lock_file"
  flock 7
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%F %T %Z')" \
    "${VW_PERF_OPERATION:-unknown}" \
    "${VW_PERF_RUN_ID:-unknown}" \
    "$stage" "$duration_ms" "$status" "$bytes" >> "${VW_PERF_FILE:-$VW_PERF_FILE_DEFAULT}"
  flock -u 7
  exec 7>&-
}

vw_perf_stage_begin() {
  [[ "${VW_PERF_STARTED:-0}" == 1 && "${VW_PERF_FINISHED:-0}" != 1 ]] || return 0
  if [[ -n "${VW_PERF_CURRENT_STAGE:-}" ]]; then
    vw_perf_stage_end interrupted 0
  fi
  VW_PERF_CURRENT_STAGE="$1"
  VW_PERF_STAGE_START_MS=$(vw_perf_now_ms)
}

vw_perf_stage_end() {
  local status="${1:-success}" bytes="${2:-0}" now elapsed
  [[ -n "${VW_PERF_CURRENT_STAGE:-}" ]] || return 0
  now=$(vw_perf_now_ms)
  elapsed=$((now - ${VW_PERF_STAGE_START_MS:-now}))
  (( elapsed < 0 )) && elapsed=0
  vw_perf_append_row "$VW_PERF_CURRENT_STAGE" "$elapsed" "$status" "$bytes"
  printf '[耗时] %-28s %8.3f 秒 (%s)\n' "$VW_PERF_CURRENT_STAGE" "$(awk -v ms="$elapsed" 'BEGIN{printf "%.3f",ms/1000}')" "$status"
  VW_PERF_CURRENT_STAGE=""
  VW_PERF_STAGE_START_MS=""
}

vw_perf_finish() {
  local status="${1:-success}" now elapsed
  [[ "${VW_PERF_STARTED:-0}" == 1 && "${VW_PERF_FINISHED:-0}" != 1 ]] || return 0
  if [[ -n "${VW_PERF_CURRENT_STAGE:-}" ]]; then
    vw_perf_stage_end "$status" 0
  fi
  now=$(vw_perf_now_ms)
  elapsed=$((now - ${VW_PERF_TOTAL_START_MS:-now}))
  (( elapsed < 0 )) && elapsed=0
  vw_perf_append_row TOTAL "$elapsed" "$status" "${VW_PERF_ARTIFACT_BYTES:-0}"
  printf '[耗时] %-28s %8.3f 秒 (%s)\n' "TOTAL ${VW_PERF_OPERATION:-operation}" "$(awk -v ms="$elapsed" 'BEGIN{printf "%.3f",ms/1000}')" "$status"
  VW_PERF_FINISHED=1
  export VW_PERF_FINISHED
}
