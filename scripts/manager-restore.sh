#!/usr/bin/env bash
# shellcheck shell=bash
# Restore: backup selection, production restore, verification, isolated rehearsal and deployment manifest view.
# Sourced by vw-manager.sh through vbm_source_trusted; relies on its globals and helpers.

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
