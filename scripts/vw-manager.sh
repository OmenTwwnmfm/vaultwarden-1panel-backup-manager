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
MANAGER_MODULES=(manager-ops.sh manager-systemd.sh manager-github.sh manager-config.sh manager-backup.sh manager-ui.sh manager-restore.sh)
MANAGER_MODULE_DIR=$(dirname -- "$COMMON_LIB")
for manager_module in "${MANAGER_MODULES[@]}"; do
  vbm_source_trusted "$MANAGER_MODULE_DIR/$manager_module" || exit 1
done
unset manager_module




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
