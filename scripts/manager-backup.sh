#!/usr/bin/env bash
# shellcheck shell=bash
# Backup: manual backup run/menu and backup history management.
# Sourced by vw-manager.sh through vbm_source_trusted; relies on its globals and helpers.

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
