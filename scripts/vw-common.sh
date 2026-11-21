#!/usr/bin/env bash
# Shared helpers for Vaultwarden 1Panel Backup Manager.
# This library intentionally discovers the running Vaultwarden container from
# Docker on every operation instead of trusting a container name saved earlier.

vw_error() { printf '[错误] %s\n' "$*" >&2; }
vw_info()  { printf '[信息] %s\n' "$*"; }
vw_ok()    { printf '[完成] %s\n' "$*"; }

# Results are exported through these globals:
# VW_DETECTED_CONTAINER, VW_DETECTED_IMAGE, VW_DETECTED_STATUS, VW_DETECTED_DATA_DIR
vw_find_target() {
  local preferred_container="${1:-}" preferred_data_dir="${2:-}" require_running="${3:-true}"
  local id name image status source canonical lower
  local -a ids=() names=() images=() statuses=() sources=()
  local -a preferred_matches=() path_matches=()

  command -v docker >/dev/null 2>&1 || { vw_error '找不到 docker 命令。'; return 1; }
  mapfile -t ids < <(docker ps -aq)
  ((${#ids[@]} > 0)) || { vw_error 'Docker 中没有任何容器。'; return 1; }

  for id in "${ids[@]}"; do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##') || continue
    image=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null) || continue
    status=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null) || continue
    lower="${name,,} ${image,,}"

    # 1Panel may name the container "bitwarden", while its image is
    # vaultwarden/server. Accept Vaultwarden image or a Bitwarden-like name,
    # but still require a real /data mount and a non-empty SQLite database.
    [[ "$lower" == *vaultwarden* || "$lower" == *bitwarden* ]] || continue
    if [[ "$require_running" == "true" && "$status" != "running" ]]; then
      continue
    fi

    source=$(docker inspect "$id" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d')
    [[ -n "$source" && "$source" != *$'\n'* ]] || continue
    [[ -d "$source" && -s "$source/db.sqlite3" ]] || continue
    canonical=$(readlink -f -- "$source" 2>/dev/null) || continue
    case "$canonical" in
      /|/var|/var/lib|/var/lib/docker|/opt|/root|/home|/etc|/usr) continue ;;
    esac

    names+=("$name")
    images+=("$image")
    statuses+=("$status")
    sources+=("$canonical")
  done

  ((${#names[@]} > 0)) || {
    if [[ "$require_running" == "true" ]]; then
      vw_error '没有找到正在运行、挂载 /data 且包含非空 db.sqlite3 的 Vaultwarden 容器。'
    else
      vw_error '没有找到挂载 /data 且包含非空 db.sqlite3 的 Vaultwarden 容器。'
    fi
    return 1
  }

  local preferred_data_canonical="" preferred_data_configured=0
  if [[ -n "$preferred_data_dir" ]]; then
    preferred_data_configured=1
    if [[ ! -d "$preferred_data_dir" ]]; then
      vw_error "配置中的数据目录不存在：$preferred_data_dir。为避免误备份新建的空实例，请先运行管理器菜单 1 重新确认数据目录。"
      return 2
    fi
    preferred_data_canonical=$(readlink -f -- "$preferred_data_dir" 2>/dev/null) || {
      vw_error "无法解析配置中的数据目录：$preferred_data_dir"
      return 1
    }
  fi

  local chosen=-1 i
  # When an existing DATA_DIR is configured, it is the primary identity of the
  # Vaultwarden data set. A container with a different /data Source is never
  # auto-selected, even when it is the only candidate. This avoids silently
  # backing up a newly-created empty instance after an accidental reinstall.
  if ((preferred_data_configured == 1)); then
    for i in "${!names[@]}"; do
      [[ "${sources[$i]}" == "$preferred_data_canonical" ]] && path_matches+=("$i")
    done
    if ((${#path_matches[@]} == 1)); then
      chosen=${path_matches[0]}
    elif ((${#path_matches[@]} > 1)); then
      vw_error "多个 Vaultwarden 容器共用已配置的数据目录 $preferred_data_canonical，无法安全自动选择。请在交互菜单重新选择。"
      return 2
    else
      vw_error "发现 Vaultwarden 容器，但没有任何容器挂载已配置的数据目录 $preferred_data_canonical。为防止备份错误实例，请运行管理器菜单 1 重新确认。"
      for i in "${!names[@]}"; do
        printf '  - %s | %s | %s | /data=%s\n' "${names[$i]}" "${images[$i]}" "${statuses[$i]}" "${sources[$i]}" >&2
      done
      return 2
    fi
  else
    # First-time discovery without a saved data directory: only auto-select a
    # single valid candidate. Multiple candidates require an explicit choice.
    if [[ -n "$preferred_container" ]]; then
      for i in "${!names[@]}"; do
        if [[ "${names[$i]}" == "$preferred_container" ]]; then
          chosen=$i
          break
        fi
      done
    fi
    if ((chosen < 0)); then
      if ((${#names[@]} == 1)); then
        chosen=0
      else
        vw_error '发现多个有效 Vaultwarden 容器，无法在无人值守任务中安全猜测。请先运行管理器菜单 1 重新选择目标。'
        for i in "${!names[@]}"; do
          printf '  - %s | %s | %s | /data=%s\n' "${names[$i]}" "${images[$i]}" "${statuses[$i]}" "${sources[$i]}" >&2
        done
        return 2
      fi
    fi
  fi

  VW_DETECTED_CONTAINER="${names[$chosen]}"
  VW_DETECTED_IMAGE="${images[$chosen]}"
  VW_DETECTED_STATUS="${statuses[$chosen]}"
  VW_DETECTED_DATA_DIR="${sources[$chosen]}"
  export VW_DETECTED_CONTAINER VW_DETECTED_IMAGE VW_DETECTED_STATUS VW_DETECTED_DATA_DIR
  return 0
}

vw_save_config() {
  # All values originate from the root-owned mode-600 config or Docker inspect.
  # printf %q emits shell-safe assignments for paths containing spaces.
  local tmp var
  [[ -n "${CONFIG_FILE:-}" ]] || return 1
  tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
  {
    for var in CONTAINER DATA_DIR AGE_RECIPIENT GITHUB_REPO GITHUB_BRANCH GITHUB_SSH_KEY BACKUP_DIR REPO_DIR RETENTION_DAYS MAX_FILE_MIB AGE_IDENTITY_DEFAULT; do
      printf '%s=%q\n' "$var" "${!var-}"
    done
  } > "$tmp"
  chmod 600 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$CONFIG_FILE"
}

vw_format_bytes() {
  local bytes="${1:-0}"
  awk -v n="$bytes" 'BEGIN {
    if (n >= 1048576) printf "%.2f MiB (%s bytes)", n/1048576, n;
    else if (n >= 1024) printf "%.2f KiB (%.2f MiB; %s bytes)", n/1024, n/1048576, n;
    else printf "%s bytes (%.2f KiB)", n, n/1024;
  }'
}
