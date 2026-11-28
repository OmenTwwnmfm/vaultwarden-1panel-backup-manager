#!/usr/bin/env bash
# Interactive manager for Docker-deployed Vaultwarden (1Panel, docker compose or docker run; SQLite, /data mount).
# This script does NOT install Docker, Vaultwarden, HTTPS, or reverse proxy.
set -Eeuo pipefail
umask 077
unset VW_CONFIG_FILE VW_LOG_FILE VW_LOCK_FILE VW_STATE_DIR VW_COMMON_LIB VW_MANIFEST_TOOL VW_ARCHIVE_CHECK_TOOL VW_MIN_FREE_MB VW_PERF_FILE VW_PERF_LOCK_FILE VW_DIAG_REPORT_DIR

VERSION="1.6.1"
CONFIG_FILE="/etc/vaultwarden-backup.conf"
BACKUP_SCRIPT="/usr/local/sbin/vw-backup.sh"
RESTORE_SCRIPT="/usr/local/sbin/vw-restore-prepare.sh"
MANAGER_SCRIPT="/usr/local/sbin/vw-manager.sh"
LOG_FILE="/var/log/vaultwarden-backup.log"
WEBDAV_CONFIG_FILE="/etc/vaultwarden-webdav.json"
BACKUP_SIGNING_DIR="/etc/vaultwarden-backup-signing"
BACKUP_LOCK_FILE="/run/lock/vaultwarden-backup.lock"
BACKUP_RESULT_FILE="/var/lib/vaultwarden-backup/last-result.env"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Every shared library and manager module passes the root trust check before it is sourced.
vbm_source_trusted() {
  local file="$1" owner mode
  if [[ ! -f "$file" || -L "$file" ]]; then
    printf '[错误] 拒绝加载不存在或为符号链接的脚本模块：%s\n' "$file" >&2
    return 1
  fi
  read -r owner mode < <(stat -c '%u %a' -- "$file") || { printf '[错误] 无法读取脚本模块属性：%s\n' "$file" >&2; return 1; }
  if [[ "$owner" != 0 ]] || (( (8#$mode & 022) != 0 )); then
    printf '[错误] 脚本模块必须由 root 所有且不可被组/其他用户写入：%s\n' "$file" >&2
    return 1
  fi
  # shellcheck disable=SC1090 # 模块路径在运行时确定
  source "$file"
}
COMMON_LIB="$SCRIPT_DIR/vw-common.sh"
if [[ ! -f "$COMMON_LIB" ]]; then COMMON_LIB="/usr/local/libexec/vw-common.sh"; fi
if [[ -f "$COMMON_LIB" ]]; then
  vbm_source_trusted "$COMMON_LIB" || exit 1
else
  printf '[错误] 找不到共享检测库：%s\n' "$COMMON_LIB" >&2
  exit 1
fi
STORAGE_TOOL="$SCRIPT_DIR/vw-storage.py"
[[ -f "$STORAGE_TOOL" ]] || STORAGE_TOOL="/usr/local/libexec/vw-storage.py"
MAINTENANCE_LIB="$SCRIPT_DIR/vw-maintenance.sh"
[[ -f "$MAINTENANCE_LIB" ]] || MAINTENANCE_LIB="/usr/local/libexec/vw-maintenance.sh"
vbm_source_trusted "$MAINTENANCE_LIB" || exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Manager modules live next to vw-common.sh: scripts/ in a checkout, /usr/local/libexec when installed.
MANAGER_MODULES=(manager-ops.sh manager-systemd.sh manager-github.sh manager-config.sh)
MANAGER_MODULE_DIR=$(dirname -- "$COMMON_LIB")
for manager_module in "${MANAGER_MODULES[@]}"; do
  vbm_source_trusted "$MANAGER_MODULE_DIR/$manager_module" || exit 1
done
unset manager_module

info() { printf "${BLUE}[信息]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[完成]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[注意]${NC} %s\n" "$*"; }
err() { printf "${RED}[错误]${NC} %s\n" "$*" >&2; }
pause() { read -r -p $'\n按 Enter 返回菜单... ' _ || true; }

confirm_yes() {
  local prompt="$1" answer
  printf '\n%s\n' "$prompt"
  vw_perf_user_wait_begin
  read -r -p "输入 yes 继续（其他输入均取消）: " answer || true
  vw_perf_user_wait_end
  [[ "${answer,,}" == "yes" ]]
}
confirm_yes_upper() {
  # Keep the historical function name for compatibility, but accept YES in
  # any letter case. This is case-insensitive, not a single-key confirmation.
  local prompt="$1" answer
  printf '\n%s\n' "$prompt"
  vw_perf_user_wait_begin
  read -r -p "这是有风险的操作。输入 yes 确认（大小写不敏感，例如 yes / YES / Yes）: " answer || true
  vw_perf_user_wait_end
  [[ "${answer,,}" == "yes" ]]
}
read_default() {
  local prompt="$1" default="$2" value
  vw_perf_user_wait_begin
  read -r -p "$prompt [$default]: " value || true
  vw_perf_user_wait_end
  printf '%s' "${value:-$default}"
}

paths_overlap() {
  local a="$1" b="$2"
  [[ "$a" == "$b" || "$a" == "$b/"* || "$b" == "$a/"* ]]
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 权限运行：sudo bash scripts/vw-manager.sh"
    exit 1
  fi
}

require_tty() {
  if [[ ! -t 0 ]]; then
    err "这是交互式脚本，请在 SSH 终端或 1Panel 终端中运行。"
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "没有找到 docker 命令。请先安装 Docker（可由 1Panel 管理，也可独立安装）。"
    return 1
  fi
}

run_backup_now() {
  local target="${1:-}"
  load_config || return 1
  target="${target:-$BACKUP_TARGET}"
  # Interactive/manual backup should execute the worker from the currently
  # checked-out project, not a possibly stale copy installed by an older menu
  # release. systemd continues to use /usr/local/sbin/vw-backup.sh, which is
  # synchronized by menu 07 / the startup updater.
  local worker="$BACKUP_SCRIPT" common_lib="$COMMON_LIB" manifest_tool="/usr/local/libexec/vw-manifest.py"
  [[ -f "$SCRIPT_DIR/vw-backup.sh" ]] && worker="$SCRIPT_DIR/vw-backup.sh"
  [[ -f "$SCRIPT_DIR/vw-common.sh" ]] && common_lib="$SCRIPT_DIR/vw-common.sh"
  [[ -f "$SCRIPT_DIR/vw-manifest.py" ]] && manifest_tool="$SCRIPT_DIR/vw-manifest.py"
  [[ -f "$worker" ]] || { err "找不到备份脚本：$worker。请先运行菜单 [22] 同步后台脚本。"; return 1; }
  echo "将检测容器、停止服务、完整备份并加密、启动服务并上传到 $target。"
  echo "上次记录容器：$CONTAINER"
  echo "上次记录数据目录：$DATA_DIR"
  echo "本次手动备份脚本：$worker"
  echo "性能记录文件：/var/lib/vaultwarden-backup/performance.tsv"
  echo "如果容器被重建过（例如 1Panel 更新或 docker compose up），后台脚本会优先按原数据目录重新匹配，并将新容器名写回配置。"
  if ! confirm_yes_upper "此操作会使 Vaultwarden 短暂不可用。确认立即备份？"; then warn "已取消。"; return 0; fi
  local rc=0
  if VW_COMMON_LIB="$common_lib" VW_MANIFEST_TOOL="$manifest_tool" VW_PERF_FILE="/var/lib/vaultwarden-backup/performance.tsv" bash "$worker" "$target"; then rc=0; else rc=$?; fi
  if ((rc == 0)); then
    ok "备份脚本执行完成。"
  elif ((rc == 75)); then
    warn "备份因另一个操作占用锁而跳过；请等待当前操作结束后重试。"
  else
    err "备份执行失败，先查看日志：$LOG_FILE"
  fi
  pause
  return "$rc"
}

manual_backup_menu() {
  load_config || return 1
  local target
  target=$(read_default "立即备份目标（github / webdav）" "${BACKUP_TARGET:-github}")
  [[ "$target" == github || "$target" == webdav ]] || { err "备份目标仅支持 github 或 webdav。"; return 1; }
  run_backup_now "$target"
}

clone_for_restore() {
  local url="$1" branch="$2" dest="$3" key="$4"
  make_ssh_command "$key"
  if [[ -e "$dest" ]]; then rm -rf -- "$dest"; fi
  git clone --quiet --branch "$branch" "$url" "$dest"
}

choose_backup_name() {
  local listing="$1" prompt="${2:-请选择备份编号（0 取消）}" choice index
  local -a names=()
  mapfile -t names < "$listing"
  ((${#names[@]} > 0)) || { err "没有找到备份及配套 SHA256 文件。"; return 1; }
  for index in "${!names[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${names[$index]}"
  done
  choice=$(read_default "$prompt" "0")
  [[ "$choice" == 0 ]] && return 2
  [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= ${#names[@]})) || { err "编号无效。"; return 1; }
  SELECTED_NAME="${names[$((choice - 1))]}"
}

select_source_archive() {
  local source="$1" temp_root="$2" repo_tmp="$2/repository" kind="${3:-archive}" key listing="$2/archives.txt"
  local list_option=--archives verify_command=verify
  if [[ "$kind" == manifest ]]; then
    list_option=--manifests
    verify_command=verify-member
  fi
  case "$source" in
    choose)
      source=$(read_default "备份来源（1 GitHub / 2 本地目录 / 3 WebDAV）" "1")
      case "$source" in
        1) source=github ;;
        2) source=local ;;
        3) source=webdav ;;
        *) err "来源无效。"; return 1 ;;
      esac
      select_source_archive "$source" "$temp_root" "$kind"
      return $?
      ;;
    github)
      [[ -n "$GITHUB_REPO" ]] || { err "请先配置 GitHub 仓库。"; return 1; }
      vw_require_free_space "$temp_root" "$((MIN_FREE_MB * 1024 * 1024))" "恢复下载临时目录" || return 1
      key=$(read_default "GitHub SSH 私钥路径" "$GITHUB_SSH_KEY")
      [[ -f "$key" ]] || { err "SSH 私钥不存在：$key"; return 1; }
      clone_for_restore "$GITHUB_REPO" "$GITHUB_BRANCH" "$repo_tmp" "$key" || { err "克隆 GitHub 备份仓库失败。"; return 1; }
      python3 "$STORAGE_TOOL" local-list "$repo_tmp" "$list_option" > "$listing" || return 1
      choose_backup_name "$listing" || return 1
      SELECTED_ARCHIVE="$repo_tmp/$SELECTED_NAME"
      ;;
    local|local-fixed)
      local source_listing="$temp_root/local-archives.txt"
      python3 "$STORAGE_TOOL" local-list "$BACKUP_DIR" "$list_option" > "$source_listing" || return 1
      if [[ "$source" == local-fixed ]]; then
        choose_backup_name "$source_listing" "本地备份编号（0 取消）" || return 1
      else
        choose_backup_name "$source_listing" || return 1
      fi
      SELECTED_ARCHIVE="$BACKUP_DIR/$SELECTED_NAME"
      ;;
    webdav)
      vw_require_free_space "$temp_root" "$((MIN_FREE_MB * 1024 * 1024))" "WebDAV 下载临时目录" || return 1
      if [[ "$kind" == manifest ]]; then
        python3 "$STORAGE_TOOL" list --manifests > "$listing" || return 1
      else
        python3 "$STORAGE_TOOL" list > "$listing" || return 1
      fi
      choose_backup_name "$listing" || return 1
      if [[ "$kind" == manifest ]]; then
        python3 "$STORAGE_TOOL" download-manifest "${SELECTED_NAME%.manifest.json.age}.tar.gz.age" "$repo_tmp" || return 1
      else
        python3 "$STORAGE_TOOL" download "$SELECTED_NAME" "$repo_tmp" --min-free-mb "${MIN_FREE_MB:-512}" || return 1
      fi
      SELECTED_ARCHIVE="$repo_tmp/$SELECTED_NAME"
      ;;
    *) err "备份来源无效。"; return 1 ;;
  esac
  python3 "$STORAGE_TOOL" "$verify_command" "$SELECTED_ARCHIVE" || return 1
}

manage_local_backups() (
  load_config || return 1
  local temp_root="" listing choice index name bytes count kind protection state
  trap '[[ -z "$temp_root" ]] || rm -rf -- "$temp_root"' EXIT
  mkdir -p /run/lock
  exec 8>"/run/lock/vaultwarden-backup.lock"
  flock -n 8 || { err "另一个备份、恢复或清理操作正在运行。"; return 1; }
  [[ -d "$BACKUP_DIR" ]] || { err "本地备份目录不存在：$BACKUP_DIR"; return 1; }
  temp_root=$(mktemp -d /var/tmp/vw-local-list.XXXXXX)
  listing="$temp_root/inventory.tsv"
  python3 "$STORAGE_TOOL" local-list "$BACKUP_DIR" > "$listing" || return 1
  local -a rows=()
  mapfile -t rows < "$listing"
  echo "本地备份目录 $BACKUP_DIR"
  ((${#rows[@]} > 0)) || { info "目录中没有可识别的备份文件。"; pause; return 0; }
  for index in "${!rows[@]}"; do
    IFS=$'\t' read -r name bytes count kind protection state <<< "${rows[$index]}"
    printf '  %d) %s\n     %s | %s | %s 个文件 | %s | %s\n' "$((index + 1))" "$name" "$kind" "$(vw_format_bytes "$bytes")" "$count" "$protection" "$state"
  done
  echo "删除范围为所选本地密文、SHA256 和配套部署清单。"
  choice=$(read_default "输入要删除的备份组编号（0 返回）" "0")
  [[ "$choice" == 0 ]] && return 0
  [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= ${#rows[@]})) || { err "编号无效。"; return 1; }
  IFS=$'\t' read -r name bytes count kind protection state <<< "${rows[$((choice - 1))]}"
  [[ "$protection" != 已保护 ]] || { err "备份已被 .keep 保护。"; return 1; }
  warn "将删除本地备份 $name，共 $(vw_format_bytes "$bytes")。"
  confirm_yes_upper "确认删除这组本地备份？" || return 0
  python3 "$STORAGE_TOOL" local-delete "$BACKUP_DIR" "$name" --data-dir "$DATA_DIR" --repo-dir "${REPO_DIR:-}" || return 1
  pause
)

manage_backup_history() {
  load_config || return 1
  local source
  source=$(read_default "历史备份来源（1 GitHub / 2 本地 / 3 WebDAV）" "1")
  case "$source" in
    1)
      [[ -n "$GITHUB_REPO" ]] || { err "尚未配置 GitHub。"; return 1; }
      manage_history
      ;;
    2) manage_local_backups ;;
    3) (
      local remote_archives SELECTED_NAME selection_result=0
      remote_archives=$(python3 "$STORAGE_TOOL" list) || return 1
      [[ -n "$remote_archives" ]] || { info "WebDAV vbm 目录中没有备份。"; pause; return 0; }
      echo "WebDAV vbm 目录中的备份："
      choose_backup_name <(printf '%s\n' "$remote_archives") "输入要删除的备份组编号（0 返回）" || selection_result=$?
      [[ "$selection_result" == 2 ]] && return 0
      [[ "$selection_result" == 0 ]] || return 1
      confirm_yes_upper "确认从 WebDAV vbm 目录删除 $SELECTED_NAME 及其配套文件？" || return 0
      mkdir -p "$(dirname -- "$BACKUP_LOCK_FILE")" || return 1
      exec 8>"$BACKUP_LOCK_FILE" || return 1
      flock -n 8 || { err "另一个备份、恢复或清理操作正在运行。"; return 1; }
      python3 "$STORAGE_TOOL" remote-delete "$SELECTED_NAME" || return 1
      exec 8>&-
      ok "WebDAV 备份组已删除。"
      pause
      ) ;;
    *) err "来源无效。"; return 1 ;;
  esac
}

local_backup_actions() {
  local action
  action=$(read_default "本地备份操作（1 验证 / 2 恢复 / 0 返回）" "0")
  case "$action" in
    1) verify_github_backup local-fixed ;;
    2) restore_from_github local-fixed ;;
    0) return 0 ;;
    *) err "选项无效。"; return 1 ;;
  esac
}

configure_webdav() (
  mkdir -p /run/lock
  exec 8>"/run/lock/vaultwarden-backup.lock"
  flock -n 8 || { err "另一个备份、恢复或清理操作正在运行。"; return 1; }
  local url username webdav_secret
  echo "请输入已创建的 WebDAV 专用备份目录完整 HTTPS 地址。"
  url=$(read_default "WebDAV 目录 URL" "")
  username=$(read_default "WebDAV 用户名" "")
  read -r -s -p "WebDAV 密码或应用密码（隐藏输入）: " webdav_secret || return 1
  echo
  printf '%s\0%s\0%s\0' "$url" "$username" "$webdav_secret" | python3 "$STORAGE_TOOL" configure || return 1
  unset webdav_secret
  ok "WebDAV 凭据已保存至 /etc/vaultwarden-webdav.json，权限为 600。"
)

upload_local_webdav() (
  load_config || return 1
  local temp_root=""
  trap '[[ -z "$temp_root" ]] || rm -rf -- "$temp_root"' EXIT
  mkdir -p /run/lock
  exec 8>"/run/lock/vaultwarden-backup.lock"
  flock -n 8 || { err "另一个备份、恢复或清理操作正在运行。"; return 1; }
  temp_root=$(mktemp -d /var/tmp/vw-webdav-upload.XXXXXX)
  select_source_archive local-fixed "$temp_root" || return 1
  confirm_yes "确认将 $(basename "$SELECTED_ARCHIVE") 上传到 WebDAV？" || return 0
  python3 "$STORAGE_TOOL" upload "$SELECTED_ARCHIVE" || return 1
  pause
)

restore_from_github() (
  local source="${1:-choose}"
  # Run restore in a subshell so decrypted staging data is removed even if the
  # user interrupts the operation or an unexpected command fails.
  local temp_root="" staging="" container="" stopped_by_script=0 data_change_started=0
  cleanup_restore() {
    local restore_rc=$?
    if [[ "${stopped_by_script:-0}" == "1" && "${was_running:-0}" == "1" && -n "${container:-}" ]]; then
      if [[ "${data_change_started:-0}" == "1" ]]; then
        echo "严重提醒：恢复过程中断，数据目录可能处于恢复中间状态。为避免使用不完整数据，容器保持停止。" >&2
        echo "使用原 age 私钥和回滚文件完成恢复前，不要在 1Panel 或 docker compose 中启动该容器。" >&2
      else
        vw_perf_stage_begin "cleanup_container_start_command"
        if docker start "$container" >/dev/null 2>&1; then
          stopped_by_script=0
          vw_perf_stage_end success
          vw_perf_stage_begin "cleanup_health_check_wait"
          if vw_wait_healthy "$container" 120 2 2; then
            vw_perf_stage_end aggregate
            # shellcheck disable=SC2034 # 经运行结果文件跨文件传递，供状态汇总读取
            SERVICE_RESTORED=true
            vw_perf_downtime_end aggregate
            echo "安全清理：Vaultwarden 已重新启动并通过主动健康探测：$container"
          else
            vw_perf_stage_end aggregate
            vw_perf_downtime_end aggregate
            echo "严重提醒：容器已启动，但未通过健康探测。请在 1Panel 或 docker compose 中检查：$container" >&2
          fi
        else
          vw_perf_stage_end failed
          vw_perf_downtime_end aggregate
          echo "严重提醒：自动清理时无法启动 Vaultwarden。请在 1Panel 或 docker compose 中手动启动：$container" >&2
        fi
      fi
    fi
    vw_perf_downtime_end aggregate
    [[ -n "${staging:-}" ]] && rm -rf -- "$staging"
    [[ -n "${temp_root:-}" ]] && rm -rf -- "$temp_root"
    if [[ "${VW_PERF_STARTED:-0}" == 1 && "${VW_PERF_FINISHED:-0}" != 1 ]]; then
      if (( restore_rc == 0 )); then vw_perf_finish success; else vw_perf_finish failed; fi
    fi
    return 0
  }
  trap cleanup_restore EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  require_docker || return 1
  load_config || return 1
  [[ -x "$RESTORE_SCRIPT" ]] || { err "恢复准备脚本尚未安装，请先运行菜单 1。"; return 1; }
  local identity archive container_state data_dir rollback_archive timestamp identity_pub start_choice
  mkdir -p /run/lock
  exec 8>"/run/lock/vaultwarden-backup.lock"
  if ! flock -n 8; then
    err "检测到另一个备份/恢复操作正在运行。请等它结束后再试。"
    return 1
  fi
  temp_root=$(mktemp -d "/var/tmp/vw-${source}-restore.XXXXXX")
  chmod 700 "$temp_root"
  vw_require_free_space "$temp_root" "$((MIN_FREE_MB * 1024 * 1024))" "恢复下载临时目录" || { err "临时目录剩余空间不足，恢复已停止。"; rm -rf -- "$temp_root"; return 1; }
  timestamp=$(date '+%Y%m%d-%H%M%S')
  local run_id="${timestamp}-$$"
  vw_perf_init restore "$run_id"
  local acquisition_stage="$source"
  [[ "$source" == choose ]] && acquisition_stage=backup
  vw_perf_stage_begin "${acquisition_stage}_acquire_backup"
  select_source_archive "$source" "$temp_root" || return 1
  archive="$SELECTED_ARCHIVE"
  vw_perf_stage_end success
  if [[ ! -f "$archive.sha256" ]]; then err "找不到对应 SHA256 文件：$archive.sha256"; rm -rf -- "$temp_root"; return 1; fi

  echo
  echo "========== 第 2 步：选择原 age 私钥 =========="
  identity=$(read_default "原 age 私钥文件路径（不是 age 公钥）" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}")
  if [[ ! -f "$identity" ]]; then err "找不到 age 私钥：$identity。请从离线介质安全复制到服务器后重试。"; rm -rf -- "$temp_root"; return 1; fi
  chmod 600 "$identity" 2>/dev/null || true
  identity_pub=$(age-keygen -y "$identity") || { err "无法读取 age 私钥。"; rm -rf -- "$temp_root"; return 1; }
  if [[ "$identity_pub" != "$AGE_RECIPIENT" ]]; then
    err "所选私钥对应的公钥与当前配置 AGE_RECIPIENT 不一致。请使用生成这些备份时的原始私钥。"
    rm -rf -- "$temp_root"
    return 1
  fi

  echo
  echo "========== 第 3 步：校验、解密并暂存 =========="
  timestamp="$(date '+%Y%m%d-%H%M%S')-$$"
  staging="$temp_root/staging"
  if [[ -e "$staging" ]]; then err "暂存目录已存在：$staging"; rm -rf -- "$temp_root"; return 1; fi
  vw_perf_stage_begin "restore_decrypt_validate"
  accept_backup_signature "$archive" || return 1
  if ! VW_ALLOW_UNSIGNED="$ALLOW_UNSIGNED" VW_MIN_FREE_MB="${MIN_FREE_MB:-512}" VW_STORAGE_TOOL="$STORAGE_TOOL" bash "$RESTORE_SCRIPT" "$archive" "$identity" "$staging"; then
    err "校验或解密失败。原 Vaultwarden 数据尚未修改。"
    rm -rf -- "$staging" "$temp_root"
    return 1
  fi
  ok "已解密并暂存到：$staging/data"
  vw_perf_stage_end success

  echo
  echo "========== 第 4 步：检查恢复目标 =========="
  if ! list_vaultwarden_containers; then rm -rf -- "$staging" "$temp_root"; return 1; fi
  vw_perf_stage_begin "restore_target_preflight"
  container="$DETECTED_CONTAINER"
  if ! inspect_data_mount "$container"; then rm -rf -- "$staging" "$temp_root"; return 1; fi
  data_dir="$DETECTED_DATA_DIR"
  if ! container_state=$(docker inspect -f '{{.State.Status}}' "$container"); then
    err "无法读取容器状态。"
    rm -rf -- "$staging" "$temp_root"
    return 1
  fi
  [[ "${MIN_FREE_MB:-}" =~ ^[0-9]+$ ]] || { err "恢复空间阈值配置无效。"; rm -rf -- "$staging" "$temp_root"; return 1; }
  CURRENT_DATA_BYTES=$(du -sb "$data_dir" | awk '{print $1}') || { err "无法读取当前数据目录大小。"; rm -rf -- "$staging" "$temp_root"; return 1; }
  RESTORE_DATA_BYTES=$(du -sb "$staging/data" | awk '{print $1}') || { err "无法读取恢复暂存目录大小。"; rm -rf -- "$staging" "$temp_root"; return 1; }
  [[ "$CURRENT_DATA_BYTES" =~ ^[0-9]+$ && "$RESTORE_DATA_BYTES" =~ ^[0-9]+$ ]] || { err "无法确定当前或恢复数据大小。"; rm -rf -- "$staging" "$temp_root"; return 1; }
  MIN_FREE_BYTES=$((MIN_FREE_MB * 1024 * 1024))
  RESTORE_TARGET_REQUIRED=$(( RESTORE_DATA_BYTES > CURRENT_DATA_BYTES ? RESTORE_DATA_BYTES - CURRENT_DATA_BYTES : 0 ))
  RESTORE_TARGET_REQUIRED=$((RESTORE_TARGET_REQUIRED + MIN_FREE_BYTES))
  vw_require_free_space "$data_dir" "$RESTORE_TARGET_REQUIRED" "Vaultwarden 数据分区" || {
    err "生产数据分区空间不足，原数据保持不变。"
    rm -rf -- "$staging" "$temp_root"
    return 1
  }
  ROLLBACK_REQUIRED=$((CURRENT_DATA_BYTES + CURRENT_DATA_BYTES / 5))
  if (( ROLLBACK_REQUIRED < MIN_FREE_BYTES )); then ROLLBACK_REQUIRED="$MIN_FREE_BYTES"; fi
  timestamp="$(date '+%Y%m%d-%H%M%S')-$$"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  vw_require_free_space "$BACKUP_DIR" "$ROLLBACK_REQUIRED" "恢复前回滚快照目录" || {
    err "恢复前回滚快照目录空间不足，原数据保持不变。"
    rm -rf -- "$staging" "$temp_root"
    return 1
  }
  rollback_archive="$BACKUP_DIR/pre-restore-${timestamp}.tar.gz.age"
  if [[ -e "$rollback_archive" ]]; then err "恢复前快照文件已存在：$rollback_archive"; return 1; fi
  vw_perf_stage_end success

  echo
  printf '选中的备份：%s\n目标容器：%s\n当前容器状态：%s\n将恢复到的数据目录：%s\n当前数据加密留存到：%s\n' \
    "$(basename "$archive")" "$container" "$container_state" "$data_dir" "$rollback_archive"
  warn "恢复会替换 /data 目录内的全部内容。为兼容 Docker 命名卷，不会移动挂载点本身；脚本会先用 age 公钥把当前数据加密保存到本地回滚文件。"
  if ! confirm_yes_upper "请再次核对容器和路径。确认将所选备份恢复到该 Vaultwarden 实例？"; then
    warn "已取消。暂存解密数据将被清理，原数据保持不变。"
    return 0
  fi

  local was_running=0 rollback_ok=0
  [[ "$container_state" == "running" ]] && was_running=1
  vw_perf_stage_begin "restore_container_stop"
  if (( was_running == 1 )); then vw_perf_downtime_begin; fi
  info "正在确认目标容器身份并停止服务：$container"
  local stop_rc=0
  if vw_ensure_target_stopped "$container" "$data_dir" 30; then stop_rc=0; else stop_rc=$?; fi
  if [[ "${VW_CONTAINER_STOPPED_BY_HELPER:-0}" == 1 ]]; then
    stopped_by_script=1
    was_running=1
  fi
  if (( stop_rc != 0 )); then
    err "无法唯一确认目标容器已停止，未修改生产数据。"
    return 1
  fi
  container="$VW_DETECTED_CONTAINER"
  data_dir="$VW_DETECTED_DATA_DIR"
  if [[ "${VW_CONTAINER_STOPPED_BY_HELPER:-0}" == 1 ]]; then
    stopped_by_script=1
    was_running=1
    vw_perf_stage_end success
  else
    vw_perf_stage_end skipped
  fi

  vw_perf_stage_begin "rollback_snapshot_encrypt_validate"
  # Create an encrypted pre-restore snapshot before changing anything. The original
  # age identity supplied above can decrypt it if the restore must be rolled back.
  echo "正在加密保存当前 /data，以便恢复失败时回滚..."
  if ! tar --numeric-owner -czpf - -C "$data_dir" . | age -r "$AGE_RECIPIENT" -o "$rollback_archive"; then
    err "创建恢复前加密快照失败，当前数据目录尚未修改。"
    rm -f -- "$rollback_archive"
    if ((was_running == 1)); then
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 或 docker compose 中手动启动容器。"; fi
    fi
    return 1
  fi
  if [[ ! -s "$rollback_archive" ]]; then
    err "恢复前加密快照为空，当前数据目录尚未修改。"
    rm -f -- "$rollback_archive"
    if ((was_running == 1)); then
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 或 docker compose 中手动启动容器。"; fi
    fi
    return 1
  fi
  (cd "$BACKUP_DIR" && sha256sum "$(basename "$rollback_archive")" > "$(basename "$rollback_archive").sha256")
  if [[ -e "$BACKUP_SIGNING_DIR/backup" ]]; then
    python3 "$STORAGE_TOOL" sign "$rollback_archive" || { err "回滚快照签名失败，生产数据尚未替换。"; return 1; }
  fi
  if ! (cd "$BACKUP_DIR" && sha256sum -c "$(basename "$rollback_archive").sha256") || ! age -d -i "$identity" "$rollback_archive" | tar -tzf - >/dev/null; then
    err "恢复前回滚快照校验失败，生产数据尚未替换。"
    rm -f -- "$rollback_archive" "$rollback_archive.sha256" "$rollback_archive.sha256.sig"
    if ((was_running == 1)); then
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 或 docker compose 中手动启动容器。"; fi
    fi
    return 1
  fi

  vw_perf_stage_end success
  vw_perf_stage_begin "replace_production_data"

  # Keep the Docker bind/named-volume mountpoint itself intact. Only replace its
  # contents, so Docker/1Panel continues mounting the same Source path.
  rollback_from_snapshot() {
    find "$data_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || return 1
    age -d -i "$identity" "$rollback_archive" | tar --numeric-owner --same-owner -xzpf - -C "$data_dir" || return 1
    [[ -f "$data_dir/db.sqlite3" ]]
  }

  echo "正在再次确认容器已停止且 /data 身份未变化..."
  stop_rc=0
  if vw_ensure_target_stopped "$container" "$data_dir" 30; then stop_rc=0; else stop_rc=$?; fi
  if [[ "${VW_CONTAINER_STOPPED_BY_HELPER:-0}" == 1 ]]; then stopped_by_script=1; fi
  if (( stop_rc != 0 )); then
    err "覆盖前无法确认目标容器已停止；保留解密暂存与加密回滚快照。"
    return 1
  fi
  container="$VW_DETECTED_CONTAINER"
  data_dir="$VW_DETECTED_DATA_DIR"
  if [[ "${VW_CONTAINER_STOPPED_BY_HELPER:-0}" == 1 ]]; then stopped_by_script=1; fi
  echo "正在替换 /data 目录内容..."
  data_change_started=1
  if ! find "$data_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; then
    err "清理原 /data 目录内容失败，正在回滚。"
    if rollback_from_snapshot; then
      rollback_ok=1
      data_change_started=0
      ok "原数据已从加密回滚快照恢复。"
    else
      err "严重错误：自动回滚失败！容器保持停止。回滚文件保留在：$rollback_archive"
    fi
    if ((was_running == 1 && rollback_ok == 1)); then
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 或 docker compose 中手动启动容器。"; fi
    fi
    return 1
  fi

  if ! cp -a "$staging/data/." "$data_dir/" || [[ ! -f "$data_dir/db.sqlite3" ]]; then
    err "复制恢复数据失败，正在从加密的恢复前快照回滚。"
    if rollback_from_snapshot; then
      rollback_ok=1
      data_change_started=0
      ok "原数据已从加密回滚快照恢复。"
    else
      err "严重错误：自动回滚失败！容器保持停止。回滚文件保留在：$rollback_archive"
      err "请勿删除该文件或当前数据目录；需要使用原 age 私钥手动解密恢复。"
    fi
    if ((was_running == 1 && rollback_ok == 1)); then
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 或 docker compose 中手动启动容器。"; fi
    fi
    return 1
  fi
  data_change_started=0
  vw_perf_stage_end success

  ok "数据恢复文件已复制完成。原数据的加密回滚快照保留在：$rollback_archive"
  start_choice="yes"
  if ((was_running == 0)); then
    start_choice=$(read_default "原容器此前已停止。是否现在启动恢复后的 Vaultwarden？输入 yes 启动，no 保持停止" "yes")
  else
    start_choice="yes"
  fi
  if [[ "${start_choice,,}" == "yes" ]]; then
    vw_perf_stage_begin "restore_container_start_command"
    if docker start "$container" >/dev/null; then
      stopped_by_script=0
      vw_perf_stage_end success
    else
      vw_perf_stage_end failed
      err "恢复后的容器启动命令失败，准备回滚到恢复前数据。"
      start_choice="start_failed"
    fi
    if [[ "$start_choice" != "start_failed" ]]; then
      vw_perf_stage_begin "restore_health_check_wait"
      if vw_wait_healthy "$container" 120 2 2; then
        vw_perf_stage_end aggregate
        vw_perf_downtime_end aggregate
        ok "恢复后的 Vaultwarden 已通过连续主动健康探测。"
      else
        vw_perf_stage_end aggregate
        err "恢复后的实例未通过主动健康探测，准备回滚到恢复前数据。"
        start_choice="health_failed"
      fi
    fi
    if [[ "$start_choice" == "start_failed" || "$start_choice" == "health_failed" ]]; then
      vw_perf_stage_begin "restore_rollback_container_stop"
      stop_rc=0
      if vw_ensure_target_stopped "$container" "$data_dir" 20; then stop_rc=0; else stop_rc=$?; fi
      if (( stop_rc != 0 )); then
        vw_perf_stage_end failed
        err "无法唯一确认目标容器已停止；为避免在线修改数据，自动回滚已中止。回滚快照保留在：$rollback_archive"
        data_change_started=0
        stopped_by_script=0
        rm -rf -- "$staging" "$temp_root"
        return 1
      fi
      container="$VW_DETECTED_CONTAINER"
      data_dir="$VW_DETECTED_DATA_DIR"
      [[ "${VW_CONTAINER_STOPPED_BY_HELPER:-0}" == 1 ]] && stopped_by_script=1
      vw_perf_stage_end success
      data_change_started=1
      vw_perf_stage_begin "restore_rollback_previous_data"
      if rollback_from_snapshot; then
        vw_perf_stage_end success
        data_change_started=0
        vw_perf_stage_begin "restore_rollback_container_start"
        if docker start "$container" >/dev/null; then
          stopped_by_script=0
          vw_perf_stage_end success
          vw_perf_stage_begin "restore_rollback_health_wait"
          if vw_wait_healthy "$container" 120 2 2; then
            vw_perf_stage_end aggregate
            # shellcheck disable=SC2034 # 经运行结果文件跨文件传递，供状态汇总读取
            SERVICE_RESTORED=true
            vw_perf_downtime_end aggregate
            warn "已自动回滚到恢复前数据并成功启动。原回滚文件仍保留：$rollback_archive"
          else
            vw_perf_stage_end aggregate
            vw_perf_downtime_end aggregate
            data_change_started=0
            vw_perf_stage_begin "restore_rollback_unhealthy_container_stop"
            if docker stop --time 20 "$container" >/dev/null 2>&1; then
              stopped_by_script=0
              vw_perf_stage_end success
              err "原数据已恢复，但回滚后的容器未通过健康检查，已停止容器。请用 docker logs 检查容器日志。"
            else
              stopped_by_script=0
              vw_perf_stage_end failed
              err "原数据已恢复，但容器未通过健康检查且无法停止。容器仍在运行，请立即检查该容器；不要再次覆盖数据。"
            fi
          fi
        else
          vw_perf_stage_end failed
          stopped_by_script=1
          data_change_started=0
          err "原数据已恢复，但容器启动失败。请用 docker logs 检查容器启动状态。"
        fi
      else
        vw_perf_stage_end failed
        stopped_by_script=1
        data_change_started=1
        err "严重错误：自动回滚数据失败！容器保持停止。回滚文件：$rollback_archive"
        echo "请勿在 1Panel 或 docker compose 中启动容器，先检查数据目录和回滚文件。"
      fi
      rm -rf -- "$staging" "$temp_root"
      return 1
    fi
  else
    stopped_by_script=0
    vw_perf_stage_begin "restore_container_start_command"
    vw_perf_stage_end skipped
    vw_perf_stage_begin "restore_health_check_wait"
    vw_perf_stage_end skipped
    warn "已按你的选择保持容器停止。稍后可在 1Panel → 已安装应用中，或用 docker start / docker compose start 手动启动。"
  fi
  warn "请登录网页测试原用户、附件、TOTP 与同步。确认一切正常之前，不要删除原数据加密回滚快照：$rollback_archive"
  ok "恢复暂存目录将在退出菜单时自动清理。"
  vw_perf_finish success
  pause
)

verify_github_backup() (
  local source="${1:-choose}"
  local temp_root="" staging_root="" identity="" identity_pub="" archive="" staging="" sqlite_result=""
  cleanup_verify() {
    [[ -n "${temp_root:-}" ]] && rm -rf -- "$temp_root"
    [[ -n "${staging_root:-}" ]] && rm -rf -- "$staging_root"
    [[ -n "${staging:-}" ]] && rm -rf -- "$staging"
    return 0
  }
  trap cleanup_verify EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  require_root
  load_config || return 1
  [[ -x "$RESTORE_SCRIPT" ]] || { err "恢复准备脚本尚未安装，请先运行菜单 [22] 同步后台脚本。"; return 1; }
  command -v sqlite3 >/dev/null 2>&1 || { err "恢复验证需要 sqlite3 执行数据库完整性检查。请先安装依赖。"; return 1; }
  mkdir -p /run/lock
  exec 8>"/run/lock/vaultwarden-backup.lock"
  flock -n 8 || { err "另一个备份、恢复或清理操作正在运行。"; return 1; }
  temp_root=$(mktemp -d "/var/tmp/vw-${source}-verify.XXXXXX")
  chmod 700 "$temp_root"
  select_source_archive "$source" "$temp_root" || return 1
  archive="$SELECTED_ARCHIVE"
  [[ -s "$archive" && -s "$archive.sha256" ]] || { err "备份文件或 SHA256 文件不存在/为空。"; return 1; }
  echo
  echo "第 1 项：SHA256 校验"
  python3 "$STORAGE_TOOL" verify "$archive" || return 1
  echo
  echo "第 2 项：验证 age 私钥"
  identity=$(read_default "原 age 私钥文件路径（必须与此备份匹配）" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}")
  [[ -f "$identity" ]] || { err "找不到 age 私钥：$identity"; return 1; }
  identity_pub=$(age-keygen -y "$identity") || { err "无法读取 age 私钥。"; return 1; }
  [[ "$identity_pub" == "$AGE_RECIPIENT" ]] || { err "该私钥对应的公钥与当前配置不匹配。"; return 1; }
  echo
  echo "第 3 项：实际解密、读取归档目录"
  staging_root=$(vw_require_tmpfs_dir "vw-${source}-verify") || {
    err "本地解密验证需要可用的 /dev/shm tmpfs；已停止，避免把明文写入持久磁盘。"
    return 1
  }
  staging="$staging_root/staging"
  accept_backup_signature "$archive" || return 1
  VW_ALLOW_UNSIGNED="$ALLOW_UNSIGNED" VW_MIN_FREE_MB="${MIN_FREE_MB:-512}" VW_STORAGE_TOOL="$STORAGE_TOOL" bash "$RESTORE_SCRIPT" "$archive" "$identity" "$staging" || { err "解密或归档检查失败。"; return 1; }
  echo
  echo "第 4 项：检查关键数据文件"
  [[ -s "$staging/data/db.sqlite3" ]] || { err "数据库缺失或为空。"; return 1; }
  printf 'db.sqlite3：%s bytes\n' "$(stat -c '%s' "$staging/data/db.sqlite3")"
  for item in attachments sends config.json rsa_key.pem rsa_key.pub; do
    if [[ -e "$staging/data/$item" ]]; then
      printf '发现：%s\n' "$item"
    fi
  done
  if command -v sqlite3 >/dev/null 2>&1; then
    echo "第 5 项：SQLite quick_check"
    sqlite_result=$(sqlite3 -readonly "$staging/data/db.sqlite3" 'PRAGMA quick_check;' 2>&1) || { err "SQLite quick_check 执行失败：$sqlite_result"; return 1; }
    [[ "$sqlite_result" == "ok" ]] || { err "SQLite 检查未返回 ok：$sqlite_result"; return 1; }
    ok "SQLite quick_check：OK"
  else
    warn "跳过 SQLite quick_check（未安装 sqlite3），但文件解密和 tar 读取已通过。"
  fi
  echo
  ok "备份验证通过：SHA256、age 解密、tar 读取和数据库文件检查均成功。"
  mkdir -p -- "$(dirname -- "$BACKUP_RESULT_FILE")"
  touch "$(dirname -- "$BACKUP_RESULT_FILE")/decrypt-verified"
  echo "这只是离线数据可读性测试，不会停止或修改当前 Vaultwarden。"
  echo "验证文件：$(basename "$archive")"
  pause
)


restore_rehearsal() (
  set -Eeuo pipefail
  local temp_root="" staging_root="" identity="" archive="" staging="" container="" image="" test_name="" state="" health=""
  cleanup_rehearsal() {
    if [[ -n "${test_name:-}" ]] && docker inspect "$test_name" >/dev/null 2>&1; then
      docker rm -f "$test_name" >/dev/null 2>&1 || true
    fi
    [[ -n "${temp_root:-}" ]] && rm -rf -- "$temp_root"
    [[ -n "${staging_root:-}" ]] && rm -rf -- "$staging_root"
    return 0
  }
  trap cleanup_rehearsal EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  require_root
  require_docker || return 1
  load_config || return 1
  [[ -x "$RESTORE_SCRIPT" ]] || { err "恢复准备脚本未安装，请先运行菜单 [22]。"; return 1; }
  if ! vw_find_target "$CONTAINER" "$DATA_DIR" true; then
    err "无法确认生产 Vaultwarden 容器和 /data 路径。恢复演练停止。"
    return 1
  fi
  image="$VW_DETECTED_IMAGE"
  container="$VW_DETECTED_CONTAINER"
  docker image inspect "$image" >/dev/null 2>&1 || { err "当前镜像在本机不存在：$image。请先通过 1Panel 或 docker pull 拉取后再演练。"; return 1; }
  temp_root=$(mktemp -d /var/tmp/vw-drill.XXXXXX); chmod 700 "$temp_root"
  vw_require_free_space "$temp_root" "$((MIN_FREE_MB * 1024 * 1024))" "恢复演练下载目录" || return 1
  select_source_archive choose "$temp_root" || return 1
  archive="$SELECTED_ARCHIVE"
  identity=$(read_default "原 age 私钥文件路径" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}")
  [[ -f "$identity" ]] || { err "找不到原 age 私钥。"; return 1; }
  local pub
  pub=$(age-keygen -y "$identity") || { err "无法读取 age 私钥。"; return 1; }
  [[ "$pub" == "$AGE_RECIPIENT" ]] || { err "此私钥与配置中的 AGE_RECIPIENT 不匹配。"; return 1; }
  staging_root=$(vw_require_tmpfs_dir "vw-drill") || {
    err "隔离恢复演练需要可用的 /dev/shm tmpfs；已停止，避免把明文写入持久磁盘。"
    return 1
  }
  staging="$staging_root/staging"
  accept_backup_signature "$archive" || return 1
  VW_ALLOW_UNSIGNED="$ALLOW_UNSIGNED" VW_MIN_FREE_MB="${MIN_FREE_MB:-512}" VW_STORAGE_TOOL="$STORAGE_TOOL" bash "$RESTORE_SCRIPT" "$archive" "$identity" "$staging" || { err "备份解密或 SQLite 检查失败。"; return 1; }
  local deep_check integrity_result
  deep_check=$(read_default "是否额外执行 SQLite PRAGMA integrity_check（比 quick_check 更彻底，耗时更长）yes/no" "no")
  if [[ "${deep_check,,}" == yes ]]; then
    info "正在执行 PRAGMA integrity_check..."
    integrity_result=$(sqlite3 -readonly "$staging/data/db.sqlite3" 'PRAGMA integrity_check;' 2>&1) || { err "SQLite integrity_check 执行失败：$integrity_result"; return 1; }
    [[ "$integrity_result" == ok ]] || { err "SQLite integrity_check 未通过：$integrity_result"; return 1; }
    ok "SQLite integrity_check：OK"
  fi
  test_name="vw-restore-drill-$(date +%Y%m%d%H%M%S)-$$"
  echo
  echo "========== 隔离恢复演练计划 =========="
  printf '备份文件：%s\n生产容器：%s\n测试镜像：%s\n临时容器：%s\n' "$(basename "$archive")" "$container" "$image" "$test_name"
  echo "隔离措施：--network none；不映射任何宿主机端口；仅挂载临时解密数据目录。"
  echo "测试容器可能写入其临时 /data，但不会挂载或修改生产 Vaultwarden 数据目录。"
  confirm_yes_upper "确认创建隔离的临时 Vaultwarden 容器进行启动测试？" || { warn "已取消。"; return 0; }
  docker run -d --name "$test_name" --network none --restart=no \
    --label "com.vw-backup-manager.restore-drill=true" \
    --mount "type=bind,src=$staging/data,dst=/data" "$image" >/dev/null || { err "临时容器创建失败。"; return 1; }
  local passed=0
  if vw_wait_healthy "$test_name" 120 2 2; then passed=1; fi
  state=$(docker inspect -f '{{.State.Status}}' "$test_name" 2>/dev/null || echo missing)
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$test_name" 2>/dev/null || echo unknown)
  echo
  echo "临时容器状态：$state；健康检查：$health"
  echo "临时容器启动日志："
  docker logs --tail 60 "$test_name" 2>&1 || true
  if ((passed==1)); then
    ok "隔离恢复演练通过：归档成功解密，SQLite 检查已通过，Vaultwarden 容器进程正常运行。"
    mkdir -p -- "$(dirname -- "$BACKUP_RESULT_FILE")"
    touch "$(dirname -- "$BACKUP_RESULT_FILE")/drill-verified"
    echo "本次未暴露 HTTP 端口，也未连接生产网络。"
  else
    err "隔离恢复演练未通过。生产容器和生产数据未被修改；请检查上面的临时容器日志、镜像兼容性和该备份版本。"
  fi
  docker rm -f "$test_name" >/dev/null 2>&1 || true
  test_name=""
  return $((passed==1 ? 0 : 1))
)

manage_history() (
  set -Eeuo pipefail
  load_config || return 1
  local temp repo_tmp choice action file base manifest marker_content
  local -a files=()
  mkdir -p "$(dirname -- "$BACKUP_LOCK_FILE")" || return 1
  exec 8>"$BACKUP_LOCK_FILE" || return 1
  if ! flock -n 8; then err "备份/恢复正在运行，暂时不能管理历史记录。"; return 1; fi
  temp=$(mktemp -d /var/tmp/vw-history.XXXXXX); chmod 700 "$temp"
  trap 'rm -rf -- "$temp"' EXIT
  repo_tmp="$temp/repo"
  make_ssh_command "$GITHUB_SSH_KEY"
  echo "正在读取 GitHub 当前分支的备份文件..."
  git clone --quiet --branch "$GITHUB_BRANCH" "$GITHUB_REPO" "$repo_tmp" || { err "克隆备份仓库失败。"; return 1; }
  git -C "$repo_tmp" config user.name "Vaultwarden Backup Manager"
  git -C "$repo_tmp" config user.email "vaultwarden-backup@localhost"
  mapfile -t files < <(find "$repo_tmp" -maxdepth 1 -type f -name 'vw-*.tar.gz.age' -printf '%f\n' | sort -r)
  ((${#files[@]} > 0)) || { warn "仓库当前分支没有发现加密数据备份。"; pause; return 0; }
  echo "GitHub 当前分支中的数据备份："
  local i size status
  for i in "${!files[@]}"; do
    file="${files[$i]}"; size=$(stat -c '%s' "$repo_tmp/$file" 2>/dev/null || echo 0)
    if [[ -e "$repo_tmp/$file.keep" ]]; then status="永久保留"; else status="按保留天数清理"; fi
    printf '  %2d) %-42s %-24s %s\n' "$((i+1))" "$file" "$status" "$(vw_format_bytes "$size")"
  done
  echo
  echo "操作：1 永久保留；2 取消永久保留；3 从当前分支删除；0 返回。"
  read -r -p "请选择操作: " action
  [[ "$action" =~ ^[0-3]$ ]] || { err "操作无效。"; return 1; }
  (( action == 0 )) && return 0
  read -r -p "输入备份编号: " choice || return 1
  [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= ${#files[@]})) || { err "编号无效。"; return 1; }
  file="${files[$((choice-1))]}"
  base="${file%.tar.gz.age}"
  manifest="${base}.manifest.json.age"
  case "$action" in
    1)
      if [[ -e "$repo_tmp/$file.keep" ]]; then warn "该备份已经标记为永久保留。"; pause; return 0; fi
      marker_content="Protected by Vaultwarden Backup Manager on $(date '+%F %T %Z'). This marker keeps this backup in the current Git branch and local retention cleanup."
      printf '%s\n' "$marker_content" > "$repo_tmp/$file.keep"
      if [[ -f "$repo_tmp/$manifest" ]]; then printf '%s\n' "$marker_content" > "$repo_tmp/$manifest.keep"; fi
      confirm_yes_upper "确认将 $file 标记为永久保留？自动过期清理会跳过此备份。" || { warn "已取消。"; return 0; }
      ;;
    2)
      if [[ ! -e "$repo_tmp/$file.keep" ]]; then warn "该备份没有永久保留标记。"; pause; return 0; fi
      confirm_yes_upper "确认取消 $file 的永久保留？超过 RETENTION_DAYS 后可能被自动清理。" || { warn "已取消。"; return 0; }
      rm -f -- "$repo_tmp/$file.keep" "$repo_tmp/$manifest.keep"
      ;;
    3)
      if [[ -e "$repo_tmp/$file.keep" || -L "$repo_tmp/$file.keep" || -e "$repo_tmp/$manifest.keep" || -L "$repo_tmp/$manifest.keep" ]]; then err "该备份组已标记为永久保留。请先取消保护。"; return 1; fi
      echo "将从 GitHub 当前分支删除：$file、校验文件及配套部署清单。"
      echo "注意：Git 历史提交中的旧对象仍可能保留这些数据。"
      confirm_yes_upper "确认删除这个备份？此操作会移除当前分支可见文件。" || { warn "已取消。"; return 0; }
      rm -f -- "$repo_tmp/$file" "$repo_tmp/$file.sha256" "$repo_tmp/$file.sha256.sig" "$repo_tmp/$manifest" "$repo_tmp/$manifest.sha256" "$repo_tmp/$manifest.sha256.sig" || return 1
      ;;
  esac
  git -C "$repo_tmp" add -A || return 1
  if git -C "$repo_tmp" diff --cached --quiet; then
    info "没有文件变化，无需提交。"; pause; return 0
  fi
  git -C "$repo_tmp" commit -m "Manage backup retention: ${file}" || return 1
  git -C "$repo_tmp" push origin "$GITHUB_BRANCH" || { err "GitHub 推送失败，本地副本未改动。"; return 1; }
  case "$action" in
    1)
      mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
      [[ -f "$BACKUP_DIR/$file" ]] && cp -p "$repo_tmp/$file.keep" "$BACKUP_DIR/$file.keep"
      [[ -f "$BACKUP_DIR/$manifest" && -f "$repo_tmp/$manifest.keep" ]] && cp -p "$repo_tmp/$manifest.keep" "$BACKUP_DIR/$manifest.keep"
      ok "已设置永久保留标记。自动保留策略会跳过对应备份及部署清单。" ;;
    2)
      rm -f -- "$BACKUP_DIR/$file.keep" "$BACKUP_DIR/$manifest.keep"
      ok "已取消永久保留标记。超过保留期限后可被自动清理。" ;;
    3)
      ok "已从 GitHub 当前分支删除备份。本地副本保留，可通过 [11] 单独管理。" ;;
  esac
  pause
)

view_deployment_manifest() (
  set -Eeuo pipefail
  load_config || return 1
  local temp identity file original
  temp=$(mktemp -d /var/tmp/vw-manifest.XXXXXX); chmod 700 "$temp"
  trap 'rm -rf -- "$temp"' EXIT
  select_source_archive choose "$temp" manifest || return 1
  original="$SELECTED_ARCHIVE"
  mkdir -m 700 "$temp/checked" || return 1
  file="$temp/checked/${original##*/}"
  cp -- "$original" "$file" && cp -- "$original.sha256" "$file.sha256" || return 1
  if [[ -e "$original.sha256.sig" || -L "$original.sha256.sig" ]]; then
    [[ -f "$original.sha256.sig" && ! -L "$original.sha256.sig" ]] || return 1
    cp -- "$original.sha256.sig" "$file.sha256.sig" || return 1
  fi
  python3 "$STORAGE_TOOL" verify-member "$file" || return 1
  accept_backup_signature "$file" || return 1
  identity=$(read_default "原 age 私钥文件路径" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}")
  [[ -f "$identity" ]] || { err "找不到 age 私钥。"; return 1; }
  age -d -i "$identity" "$file" > "$temp/manifest.json" || { err "部署清单解密失败。"; return 1; }
  echo "以下清单已经进行脱敏处理，秘密变量值不会显示："
  cat "$temp/manifest.json"
  echo
  warn "清单用于手动复现容器部署配置（1Panel / docker compose / docker run），不包含 SMTP 密码、Admin Token 或其他秘密值。"
  pause
)

render_main_menu() {
  local timer_status
  timer_status=$(systemctl show vw-backup.timer -p LoadState -p ActiveState 2>/dev/null) || timer_status=""
  python3 - "$VERSION" "${BACKUP_TARGET:-}" "$BACKUP_RESULT_FILE" "$timer_status" "${SYSTEMD_TIME:-}" <<'PYMENU'
from pathlib import Path
import shlex
import sys
import unicodedata

version, target, result_path, timer_status, schedule = sys.argv[1:]
targets = {"github": "GitHub", "webdav": "WebDAV"}
result = {}
try:
    with Path(result_path).open(encoding="utf-8", errors="replace") as handle:
        for line in handle.read(16384).splitlines():
            key, _, value = line.partition("=")
            if key in ("FINISHED_AT", "STATUS", "BACKUP_TARGET", "LOCAL_VERIFIED", "REMOTE_VERIFIED", "SERVICE_RESTORED"):
                try:
                    parts = shlex.split(value)
                except ValueError:
                    continue
                if len(parts) == 1 and parts[0].isprintable():
                    result[key] = parts[0]
except OSError:
    pass

def check_status(key):
    return {"true": "通过", "false": "未通过"}.get(result.get(key), "未记录")

timer_fields = timer_status.splitlines()
if "LoadState=not-found" in timer_fields:
    timer = "未安装"
elif "ActiveState=active" in timer_fields:
    timer = f"运行中 · {schedule}" if schedule else "运行中"
elif "ActiveState=inactive" in timer_fields:
    timer = "未运行"
elif "ActiveState=failed" in timer_fields:
    timer = "失败"
else:
    timer = "状态未知"
W = 82

def width(s):
    total = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        total += 2 if unicodedata.east_asian_width(ch) in ("F", "W") else 1
    return total

def pad(s, align="left"):
    s = s[:W]
    n = W - width(s)
    while n < 0:
        s = s[:-1]
        n = W - width(s)
    if align == "center":
        left = n // 2
        return " " * left + s + " " * (n-left)
    return s + " " * n

def row(s="", align="left"):
    if s and align == "left":
        s = "  " + s
    print("│" + pad(s, align) + "│")

def sep():
    print("├" + "─" * W + "┤")

print("╭" + "─" * W + "╮")
row("Vaultwarden Backup Manager", "center")
row(f"v{version} · 1Panel / Docker Compose / Docker · Ubuntu / Debian", "center")
row("Powered by OmenTwwnmfm", "center")
row()
row("1Panel / Compose 负责应用、Docker、HTTPS；本工具负责数据保护与恢复。", "center")
row("自动备份使用 systemd timer，不依赖 1Panel 计划任务或 cron。", "center")
row(f"定时备份目标：{targets.get(target, '未配置')} · 自动备份：{timer}", "center")
backup = result.get("FINISHED_AT", "未记录")
run_target = targets.get(result.get("BACKUP_TARGET"), "未知目标")
status = {"success": "成功", "failed": "失败", "running": "进行中", "skipped": "已跳过"}.get(result.get("STATUS"), "未记录")
row(f"最近备份：{backup} · {run_target} · {status}" if result else "最近备份：未记录", "center")
row(f"本地校验：{check_status('LOCAL_VERIFIED')} · 服务恢复：{check_status('SERVICE_RESTORED')} · 远端核验：{check_status('REMOTE_VERIFIED')}", "center")
sep()
sections = [
    ("01 · 快速操作", [
        "[01] 首次配置 / 重新检测容器与数据目录",
        "[02] 立即执行备份（GitHub / WebDAV）",
        "[03] 检查当前环境与备份状态"]),
    ("02 · 备份与验证", [
        "[04] 查看备份日志",
        "[05] 验证历史备份（GitHub / 本地 / WebDAV）",
        "[06] 查看加密部署清单（GitHub / 本地 / WebDAV）",
        "[07] 性能监控与执行耗时分析"]),
    ("03 · 恢复与演练", [
        "[08] 选择备份并恢复生产数据（GitHub / 本地 / WebDAV）",
        "[09] 隔离恢复演练（GitHub / 本地 / WebDAV）"]),
    ("04 · 存储与保留", [
        "[10] 历史备份文件管理（GitHub / 本地 / WebDAV）",
        "[11] 查看 / 删除本地备份（本地）",
        "[12] 配置 WebDAV 连接（WebDAV）",
        "[13] 上传 / 补传 WebDAV 备份（WebDAV）"]),
    ("05 · 自动化与安全", [
        "[14] 安装 / 修改自动备份（GitHub / WebDAV）",
        "[15] 查看定时任务状态",
        "[16] 暂停自动备份",
        "[17] 恢复自动备份",
        "[18] 配置通知与告警",
        "[19] 更新前备份保护"]),
    ("06 · 系统维护", [
        "[20] 生成系统诊断报告",
        "[21] 配置备份策略",
        "[22] 同步已安装后台脚本",
        "[23] 检查 / 更新项目源码并同步后台脚本"]),
]
for title, items in sections:
    row(title)
    for item in items:
        row("    " + item)
    sep()
row("[00] 退出")
print("╰" + "─" * W + "╯")
PYMENU
}

main_menu() {
  require_root
  if [[ "${1:-}" == status ]]; then
    load_config || return 1
    show_operational_status
    return
  fi
  require_tty
  if (($#)); then
    case "$1" in
      backup) manual_backup_menu ;;
      restore) restore_from_github choose ;;
      verify) verify_github_backup choose ;;
      drill) restore_rehearsal ;;
      *) err "用法：vbm [backup|restore|verify|status|drill]" ; return 2 ;;
    esac
    return $?
  fi
  if [[ "${VBM_SKIP_UPDATE_CHECK:-0}" == "1" ]]; then
    unset VBM_SKIP_UPDATE_CHECK
  else
    check_for_project_updates || true
  fi
  while true; do
    clear 2>/dev/null || true
    (load_config >/dev/null 2>&1 || true; render_main_menu)
    warn_if_helpers_stale
    read -r -p "请选择操作 [00-23]: " choice || exit 0
    case "$choice" in
      1|01) configure_wizard || pause ;;
      2|02) manual_backup_menu || true ;;
      3|03) check_configuration || pause ;;
      4|04) show_logs ;;
      5|05) verify_github_backup choose || pause ;;
      6|06) view_deployment_manifest || pause ;;
      7|07) performance_monitor ;;
      8|08) restore_from_github choose || pause ;;
      9|09) restore_rehearsal || true; pause ;;
      10) manage_backup_history || pause ;;
      11) manage_local_backups || pause ;;
      12) configure_webdav || true; pause ;;
      13) upload_local_webdav || pause ;;
      14) install_systemd_timer || pause ;;
      15) systemd_timer_status ;;
      16) pause_systemd_timer || pause ;;
      17) resume_systemd_timer || pause ;;
      18) configure_notifications || pause ;;
      19) preupgrade_backup || pause ;;
      20) generate_diagnostics || pause ;;
      21) configure_backup_policy || pause ;;
      22) update_installed_scripts || pause ;;
      23) check_for_project_updates || warn "本次未更新项目源码。"; pause ;;
      0|00) echo "已退出。"; exit 0 ;;
      *) warn "无效选项，请输入 00-23。"; sleep 1 ;;
    esac
  done
}

main_menu "$@"
