#!/usr/bin/env bash
# Shared helpers for Vaultwarden 1Panel Backup Manager.
set -Eeuo pipefail

vw_error() { printf '[错误] %s\n' "$*" >&2; }
vw_info()  { printf '[信息] %s\n' "$*"; }
vw_ok()    { printf '[完成] %s\n' "$*"; }

vw_require_secure_config() {
  local file="${1:-${CONFIG_FILE:-}}" owner mode directory directory_owner directory_mode
  [[ -n "$file" && -f "$file" && ! -L "$file" ]] || { vw_error "配置文件不存在或是符号链接：${file:-<empty>}"; return 1; }
  owner=$(stat -c '%u' -- "$file") || return 1
  [[ "$owner" == 0 ]] || { vw_error "配置文件必须由 root 所有：$file"; return 1; }
  directory=$(dirname -- "$file")
  directory_owner=$(stat -c '%u' -- "$directory") || return 1
  directory_mode=$(stat -c '%a' -- "$directory") || return 1
  [[ "$directory_owner" == 0 ]] && (( (8#$directory_mode & 022) == 0 )) || {
    vw_error "配置目录必须由 root 所有且不可被组/其他用户写入：$directory"
    return 1
  }
  mode=$(stat -c '%a' -- "$file") || return 1
  if [[ "$mode" != 600 ]]; then
    chmod 600 -- "$file" || { vw_error "无法收紧配置文件权限：$file"; return 1; }
  fi
  [[ "$(stat -c '%a' -- "$file")" == 600 ]]
}

vw_atomic_replace() {
  local source="$1" target="$2"
  python3 - "$source" "$target" <<'PY'
import os
import sys

source, target = sys.argv[1:]
with open(source, "rb") as handle:
    os.fsync(handle.fileno())
os.replace(source, target)
directory = os.path.dirname(target) or "."
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
descriptor = os.open(directory, flags)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

vw_require_free_space() {
  local path="$1" required_bytes="$2" label="$3" available_bytes
  [[ -d "$path" ]] || { vw_error "空间检查目录不存在：$path"; return 1; }
  [[ "$required_bytes" =~ ^[0-9]+$ ]] || { vw_error "空间检查阈值无效：$required_bytes"; return 1; }
  available_bytes=$(df -PB1 -- "$path" | awk 'NR == 2 {print $4}') || return 1
  [[ "$available_bytes" =~ ^[0-9]+$ ]] || { vw_error "无法读取文件系统剩余空间：$path"; return 1; }
  if (( available_bytes < required_bytes )); then
    vw_error "$label 空间不足：需要至少 $(vw_format_bytes "$required_bytes")，当前剩余 $(vw_format_bytes "$available_bytes")（$path）"
    return 1
  fi
}

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
  local tmp var directory directory_owner directory_mode rc
  [[ -n "${CONFIG_FILE:-}" ]] || return 1
  directory=$(dirname -- "$CONFIG_FILE")
  directory_owner=$(stat -c '%u' -- "$directory") || return 1
  directory_mode=$(stat -c '%a' -- "$directory") || return 1
  [[ "$directory_owner" == 0 ]] && (( (8#$directory_mode & 022) == 0 )) || return 1
  [[ ! -L "$CONFIG_FILE" ]] || return 1
  tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
  {
    for var in CONTAINER DATA_DIR AGE_RECIPIENT GITHUB_REPO GITHUB_BRANCH GITHUB_SSH_KEY BACKUP_DIR REPO_DIR RETENTION_DAYS MAX_FILE_MIB AGE_IDENTITY_DEFAULT SYSTEMD_TIME BACKUP_FREQUENCY MIN_FREE_MB GIT_PUSH_RETRIES GIT_RETRY_DELAY NOTIFY_METHOD TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID NTFY_URL NTFY_TOKEN WEBHOOK_URL NOTIFY_ON_SUCCESS NOTIFY_ON_FAILURE; do
      printf '%s=%q\n' "$var" "${!var-}"
    done
  } > "$tmp"
  chmod 600 -- "$tmp" || { rc=$?; rm -f -- "$tmp"; return "$rc"; }
  chown root:root -- "$tmp" || { rc=$?; rm -f -- "$tmp"; return "$rc"; }
  vw_atomic_replace "$tmp" "$CONFIG_FILE" || { rc=$?; rm -f -- "$tmp"; return "$rc"; }
  rm -f -- "$tmp"
  return 0
}

vw_find_container_by_data_dir() {
  local expected_data_dir="$1" expected_canonical id name source canonical status image health
  local -a ids=() matched_names=() matched_images=() matched_statuses=() matched_healths=()
  [[ -d "$expected_data_dir" ]] || { vw_error "Vaultwarden 数据目录不存在：$expected_data_dir"; return 1; }
  expected_canonical=$(readlink -f -- "$expected_data_dir") || return 1
  mapfile -t ids < <(docker ps -aq)
  for id in "${ids[@]}"; do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##') || continue
    source=$(docker inspect "$id" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d') || continue
    [[ -n "$source" && "$source" != *$'\n'* ]] || continue
    canonical=$(readlink -f -- "$source" 2>/dev/null) || continue
    [[ "$canonical" == "$expected_canonical" ]] || continue
    image=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null) || continue
    status=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null) || continue
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$id" 2>/dev/null || echo unknown)
    matched_names+=("$name"); matched_images+=("$image"); matched_statuses+=("$status"); matched_healths+=("$health")
  done
  if ((${#matched_names[@]} != 1)); then
    vw_error "数据目录 $expected_canonical 对应 ${#matched_names[@]} 个容器；无法安全唯一确认。"
    return 1
  fi
  VW_DETECTED_CONTAINER="${matched_names[0]}"
  VW_DETECTED_IMAGE="${matched_images[0]}"
  VW_DETECTED_STATUS="${matched_statuses[0]}"
  VW_DETECTED_DATA_DIR="$expected_canonical"
  VW_DETECTED_HEALTH="${matched_healths[0]}"
  export VW_DETECTED_CONTAINER VW_DETECTED_IMAGE VW_DETECTED_STATUS VW_DETECTED_DATA_DIR VW_DETECTED_HEALTH
}

vw_ensure_target_stopped() {
  local preferred_container="$1" expected_data_dir="$2" timeout_s="${3:-30}" status
  VW_CONTAINER_STOPPED_BY_HELPER=0
  vw_find_container_by_data_dir "$expected_data_dir" || return 1
  [[ "$VW_DETECTED_DATA_DIR" == "$(readlink -f -- "$expected_data_dir")" ]] || {
    vw_error "Vaultwarden 数据目录身份已变化，拒绝操作：$expected_data_dir"
    return 1
  }
  if [[ -n "$preferred_container" && "$preferred_container" != "$VW_DETECTED_CONTAINER" ]]; then
    vw_info "容器名称已变化；已按 /data 路径确认新容器：$preferred_container -> $VW_DETECTED_CONTAINER"
  fi
  preferred_container="$VW_DETECTED_CONTAINER"
  status=$(docker inspect -f '{{.State.Status}}' "$preferred_container" 2>/dev/null) || {
    vw_error "无法确认容器状态：$preferred_container"
    return 1
  }
  case "$status" in
    running|restarting|paused)
      if [[ "$status" == paused ]] && ! docker unpause "$preferred_container" >/dev/null; then
        vw_error "无法解除容器暂停状态：$preferred_container"
        return 1
      fi
      if ! docker stop --time "$timeout_s" "$preferred_container" >/dev/null; then
        vw_error "无法停止容器：$preferred_container"
        return 1
      fi
      VW_CONTAINER_STOPPED_BY_HELPER=1
      ;;
    created|exited|dead) ;;
    *)
      vw_error "容器状态不明确（$status），拒绝修改数据：$preferred_container"
      return 1
      ;;
  esac
  status=$(docker inspect -f '{{.State.Status}}' "$preferred_container" 2>/dev/null) || {
    vw_error "停止后无法重新确认容器状态：$preferred_container"
    return 1
  }
  case "$status" in
    created|exited|dead) ;;
    *)
      vw_error "容器停止后状态仍不安全（$status）：$preferred_container"
      return 1
      ;;
  esac
  VW_DETECTED_CONTAINER="$preferred_container"
  VW_DETECTED_STATUS="$status"
  export VW_CONTAINER_STOPPED_BY_HELPER VW_DETECTED_CONTAINER
  export VW_DETECTED_STATUS
}

vw_perf_downtime_begin() {
  [[ "${VW_PERF_STARTED:-0}" == 1 && -z "${VW_PERF_DOWNTIME_START_MS:-}" ]] || return 0
  VW_PERF_DOWNTIME_START_MS=$(vw_perf_now_ms)
}

vw_perf_downtime_end() {
  local now elapsed
  [[ -n "${VW_PERF_DOWNTIME_START_MS:-}" ]] || return 0
  now=$(vw_perf_now_ms)
  elapsed=$((now - VW_PERF_DOWNTIME_START_MS))
  (( elapsed < 0 )) && elapsed=0
  vw_perf_record_event SERVICE_DOWNTIME "$elapsed" aggregate 0
  VW_PERF_DOWNTIME_START_MS=""
}

vw_perf_user_wait_begin() {
  [[ "${VW_PERF_STARTED:-0}" == 1 && "${VW_PERF_FINISHED:-0}" != 1 ]] || return 0
  VW_PERF_USER_WAIT_START_MS=$(vw_perf_now_ms)
}

vw_perf_user_wait_end() {
  local now elapsed
  [[ -n "${VW_PERF_USER_WAIT_START_MS:-}" ]] || return 0
  now=$(vw_perf_now_ms)
  elapsed=$((now - VW_PERF_USER_WAIT_START_MS))
  (( elapsed < 0 )) && elapsed=0
  vw_perf_record_event USER_WAIT "$elapsed" informational 0
  VW_PERF_USER_WAIT_START_MS=""
}


vw_wait_healthy() {
  # Prefer an active readiness probe when the configured Docker healthcheck is
  # Vaultwarden's own /healthcheck.sh. Docker's native scheduler may run only
  # once every 60 seconds; waiting for .State.Health=healthy after docker start
  # can therefore add an avoidable minute even when /alive is already serving.
  # We execute the exact same probe twice, two seconds apart, and keep a hard
  # timeout. The Docker healthcheck itself remains enabled and unchanged.
  local container="$1" timeout_s="${2:-120}" delay_s="${3:-2}" required="${4:-2}"
  local health_test state health start_ms now_ms probe_start probe_end
  local successes=0 previous_success_ms=0 last_probe_rc=1
  local native_start native_end native_elapsed
  [[ "$timeout_s" =~ ^[0-9]+$ ]] && (( timeout_s >= 1 )) || timeout_s=120
  [[ "$delay_s" =~ ^[0-9]+$ ]] || delay_s=2
  [[ "$required" =~ ^[0-9]+$ ]] && (( required >= 1 && required <= 5 )) || required=2

  start_ms=$(vw_perf_now_ms)
  health_test=$(docker inspect -f '{{json .Config.Healthcheck.Test}}' "$container" 2>/dev/null || echo '[]')

  if [[ "$health_test" == '["CMD","/healthcheck.sh"]' ]]; then
    echo "[健康检查] 使用 Vaultwarden 原生 /healthcheck.sh 主动探测；间隔 ${delay_s}s，连续成功 ${required} 次，超时 ${timeout_s}s。"
    while :; do
      state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)
      if [[ "$state" == running ]]; then
        probe_start=$(vw_perf_now_ms)
        if timeout --signal=TERM --kill-after=2s 12s docker exec "$container" /healthcheck.sh >/dev/null 2>&1; then
          probe_end=$(vw_perf_now_ms)
          last_probe_rc=0
          if (( successes == 0 )); then
            vw_perf_record_event readiness_probe_first_success "$((probe_end - start_ms))" success 0
            echo "[健康检查] 首次主动探测成功。"
          else
            vw_perf_record_event readiness_probe_confirmation "$((probe_end - previous_success_ms))" success 0
            echo "[健康检查] 连续第 ${required} 次主动探测成功。"
          fi
          successes=$((successes + 1))
          previous_success_ms=$probe_end
          if (( successes >= required )); then
            native_start=$(vw_perf_now_ms)
            health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo unknown)
            native_end=$(vw_perf_now_ms)
            native_elapsed=$((native_end - native_start))
            vw_perf_record_event docker_native_health_observation "$native_elapsed" success 0
            if [[ "$health" == healthy ]]; then
              echo "[健康检查] Docker 原生状态：healthy。"
            elif [[ "$health" == unhealthy ]]; then
              echo "[警告] Docker 原生状态仍为 unhealthy，但与其相同的 /healthcheck.sh 已连续通过两次；原生状态可能尚未刷新，本工具以两次主动探测结果确认应用就绪。"
            else
              echo "[信息] Vaultwarden 主动健康探测已连续通过；Docker 原生状态当前为 '${health}'。原生状态会在 Docker 下一轮定时检查后更新，本工具不再被动等待 60 秒。"
            fi
            return 0
          fi
        else
          last_probe_rc=$?
          successes=0
        fi
      else
        successes=0
      fi

      now_ms=$(vw_perf_now_ms)
      if (( now_ms - start_ms >= timeout_s * 1000 )); then
        if (( successes > 0 )); then
          vw_perf_record_event readiness_probe_confirmation "$((now_ms - previous_success_ms))" failed 0
        else
          vw_perf_record_event readiness_probe_first_success "$((now_ms - start_ms))" failed 0
        fi
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo unknown)
        vw_error "主动健康探测超时：container=$container state=$state health=$health last_probe_exit=$last_probe_rc timeout=${timeout_s}s"
        return 1
      fi
      sleep "$delay_s"
    done
  fi

  # Compatibility fallback for non-standard healthchecks. This preserves the
  # native Docker healthcheck semantics for images not using /healthcheck.sh.
  echo "[健康检查] 当前镜像未配置 Vaultwarden /healthcheck.sh 探针，回退为 Docker 原生 Health 状态轮询。"
  while :; do
    state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo unknown)
    if [[ "$state" == running && ( "$health" == healthy || "$health" == no-healthcheck ) ]]; then
      now_ms=$(vw_perf_now_ms)
      vw_perf_record_event docker_native_health_poll_wait "$((now_ms - start_ms))" success 0
      if [[ "$health" == no-healthcheck ]]; then
        echo "[警告] 容器没有配置 Docker Healthcheck；本次只能确认容器处于 running，不能证明应用 HTTP 接口可用。"
      else
        echo "[健康检查] Docker 原生状态已达到 healthy。"
      fi
      return 0
    fi
    now_ms=$(vw_perf_now_ms)
    if (( now_ms - start_ms >= timeout_s * 1000 )); then
      vw_perf_record_event docker_native_health_poll_wait "$((now_ms - start_ms))" failed 0
      vw_error "容器未能在 ${timeout_s}s 内达到 running/healthy：$container（state=$state health=$health）"
      return 1
    fi
    sleep "$delay_s"
  done
}

vw_format_bytes() {
  local bytes="${1:-0}"
  awk -v n="$bytes" 'BEGIN { if (n >= 1073741824) printf "%.2f GiB (%s bytes)", n/1073741824, n; else if (n >= 1048576) printf "%.2f MiB (%s bytes)", n/1048576, n; else if (n >= 1024) printf "%.2f KiB (%.2f MiB; %s bytes)", n/1024, n/1048576, n; else printf "%s bytes (%.2f KiB)", n, n/1024; }'
}

vw_notify() {
  local event="${1:-info}" message="${2:-Vaultwarden backup event}" force="${3:-false}" config="${CONFIG_FILE:-/etc/vaultwarden-backup.conf}"
  [[ -f "$config" ]] || return 0
  vw_require_secure_config "$config" || return 1
  # Backup/restore callers deliberately ignore this status; menu tests do not.
  python3 - "$config" "$event" "$message" "$force" <<'PY'
import os, sys, urllib.request, urllib.parse, json
cfg_path, event, message, force = sys.argv[1:5]
# The config is root-owned mode 0600 and contains shell-escaped assignments.
# Source it in a child bash and export only notification variables.
keys = ["NOTIFY_METHOD", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "NTFY_URL", "NTFY_TOKEN", "WEBHOOK_URL", "NOTIFY_ON_SUCCESS", "NOTIFY_ON_FAILURE"]
cmd = 'set -a; . "$1"; for k in ' + ' '.join(keys) + '; do printf "%s=%s\\n" "$k" "${!k-}"; done'
import subprocess
p = subprocess.run(["bash", "-c", cmd, "notify-env", cfg_path], capture_output=True, text=True)
if p.returncode != 0:
    print("[WARN] Unable to load notification settings from the protected config file.", file=sys.stderr)
    sys.exit(1)
env = {}
for line in p.stdout.splitlines():
    if "=" in line:
        k, v = line.split("=", 1); env[k] = v
method = env.get("NOTIFY_METHOD", "none").lower()
if method in ("", "none", "off"):
    sys.exit(0)
if force.lower() not in ("1", "true", "yes") and event == "success" and env.get("NOTIFY_ON_SUCCESS", "true").lower() not in ("1", "true", "yes"):
    sys.exit(0)
if force.lower() not in ("1", "true", "yes") and event != "success" and env.get("NOTIFY_ON_FAILURE", "true").lower() not in ("1", "true", "yes"):
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
    sys.exit(1)
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
  if ! mkdir -p "$(dirname "$file")"; then
    echo "[WARN] 无法创建性能记录目录：$(dirname "$file")；备份/恢复继续执行，但本次不会保存性能记录。" >&2
    VW_PERF_STARTED=0
    return 0
  fi
  if ! touch "$file" || ! chmod 600 "$file"; then
    echo "[WARN] 无法创建或设置性能记录文件权限：$file；备份/恢复继续执行，但本次不会保存性能记录。" >&2
    VW_PERF_STARTED=0
    return 0
  fi
  if [[ ! -s "$file" ]]; then
    if ! printf 'timestamp\toperation\trun_id\tstage\tduration_ms\tstatus\tbytes\n' >> "$file"; then
      echo "[WARN] 无法写入性能记录表头：$file；备份/恢复继续执行，但本次不会保存性能记录。" >&2
      VW_PERF_STARTED=0
      return 0
    fi
  fi
  VW_PERF_FILE="$file"
  VW_PERF_OPERATION="$operation"
  VW_PERF_RUN_ID="$run_id"
  VW_PERF_TOTAL_START_MS=$(vw_perf_now_ms)
  VW_PERF_STAGE_START_MS=""
  VW_PERF_CURRENT_STAGE=""
  VW_PERF_DOWNTIME_START_MS=""
  VW_PERF_USER_WAIT_START_MS=""
  VW_PERF_STARTED=1
  VW_PERF_FINISHED=0
  export VW_PERF_FILE VW_PERF_OPERATION VW_PERF_RUN_ID VW_PERF_TOTAL_START_MS VW_PERF_STARTED VW_PERF_FINISHED
  echo "[性能] 已启用阶段耗时记录：$VW_PERF_FILE"
}

vw_perf_append_row() {
  local stage="$1" duration_ms="$2" status="$3" bytes="${4:-0}"
  local file="${VW_PERF_FILE:-$VW_PERF_FILE_DEFAULT}" lock_file="${VW_PERF_LOCK_FILE:-/run/lock/vaultwarden-performance.lock}"
  local timestamp
  timestamp=$(date '+%F %T %Z')
  if ! mkdir -p "$(dirname "$lock_file")" "$(dirname "$file")"; then
    echo "[WARN] 性能记录目录不可写：$(dirname "$file")" >&2
    return 0
  fi
  # Lock only the append operation; a subshell prevents the file descriptor
  # from leaking into later commands or nested functions.
  if ! (
    flock -x 9 || exit 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$timestamp" \
      "${VW_PERF_OPERATION:-unknown}" \
      "${VW_PERF_RUN_ID:-unknown}" \
      "$stage" "$duration_ms" "$status" "$bytes" >> "$file"
  ) 9>"$lock_file"; then
    echo "[WARN] 无法追加性能记录：$file（不影响备份/恢复结果）" >&2
    return 0
  fi
}

vw_perf_record_event() {
  # Record a child timing without disturbing the caller's current aggregate
  # stage. The caller records the enclosing health-check stage with status
  # "aggregate"; analytics ignore that summary row to avoid double counting.
  local stage="$1" duration_ms="$2" status="${3:-success}" bytes="${4:-0}"
  [[ "${VW_PERF_STARTED:-0}" == 1 && "${VW_PERF_FINISHED:-0}" != 1 ]] || return 0
  vw_perf_append_row "$stage" "$duration_ms" "$status" "$bytes"
  printf '[耗时] %-34s %8.3f 秒 (%s)\n' "$stage" "$(awk -v ms="$duration_ms" 'BEGIN{printf "%.3f",ms/1000}')" "$status"
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
  local status="${1:-success}" now elapsed user_wait_ms
  [[ "${VW_PERF_STARTED:-0}" == 1 && "${VW_PERF_FINISHED:-0}" != 1 ]] || return 0
  vw_perf_user_wait_end
  if [[ -n "${VW_PERF_CURRENT_STAGE:-}" ]]; then
    vw_perf_stage_end "$status" 0
  fi
  now=$(vw_perf_now_ms)
  user_wait_ms=$(awk -F '\t' -v run_id="${VW_PERF_RUN_ID:-unknown}" '$3 == run_id && $4 == "USER_WAIT" {total += $5} END {print total + 0}' "${VW_PERF_FILE:-$VW_PERF_FILE_DEFAULT}" 2>/dev/null || echo 0)
  elapsed=$((now - ${VW_PERF_TOTAL_START_MS:-now} - user_wait_ms))
  (( elapsed < 0 )) && elapsed=0
  printf '[耗时] %-28s %8.3f 秒 (informational)\n' "USER_WAIT ${VW_PERF_OPERATION:-operation}" "$(awk -v ms="$user_wait_ms" 'BEGIN{printf "%.3f",ms/1000}')"
  vw_perf_append_row TOTAL "$elapsed" "$status" "${VW_PERF_ARTIFACT_BYTES:-0}"
  printf '[耗时] %-28s %8.3f 秒 (%s)\n' "TOTAL ${VW_PERF_OPERATION:-operation}" "$(awk -v ms="$elapsed" 'BEGIN{printf "%.3f",ms/1000}')" "$status"
  VW_PERF_FINISHED=1
  export VW_PERF_FINISHED
}
