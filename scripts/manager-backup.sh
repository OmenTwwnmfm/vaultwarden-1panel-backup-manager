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
