#!/usr/bin/env bash

release_version_allowed() {
  local current="$1" candidate="$2"
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$(printf '%s\n' "$current" "$candidate" | sort -Vr | sed -n '1p')" == "$candidate" ]]
}

check_for_project_updates() {
  [[ "${VBM_SKIP_UPDATE_CHECK:-0}" == 1 ]] && return 0
  local project_root="${VBM_PROJECT_ROOT:-$(readlink -f -- "$SCRIPT_DIR/..")}"
  local target_commit remote_version current_commit working_tree answer
  [[ -d "$project_root/.git" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0
  working_tree=$(git -C "$project_root" status --porcelain) || return 1
  if [[ -n "$working_tree" ]]; then
    warn "项目有本地修改，跳过更新。"
    return 0
  fi
  timeout 20s git -C "$project_root" fetch --no-tags origin refs/heads/main || return 1
  target_commit=$(git -C "$project_root" rev-parse FETCH_HEAD) || return 1
  current_commit=$(git -C "$project_root" rev-parse HEAD) || return 1
  [[ "$current_commit" != "$target_commit" ]] || { ok "源码已与远端 main 同步。"; return 0; }
  remote_version=$(git -C "$project_root" show "$target_commit:scripts/vw-manager.sh" | sed -n 's/^VERSION="\([^"]*\)"$/\1/p') || return 1
  if ! release_version_allowed "$VERSION" "$remote_version"; then
    warn "目标版本无效或低于当前版本，更新停止。"
    return 1
  fi
  git -C "$project_root" merge-base --is-ancestor "$current_commit" "$target_commit" || { warn "更新需要快进，当前提交不在目标版本历史中。"; return 1; }
  printf '当前 v%s，远端 main 版本 v%s\n' "$VERSION" "$remote_version"
  git -C "$project_root" show "$target_commit:CHANGELOG.md" | sed -n '1,16p' || return 1
  read -r -p "输入 yes 更新并同步脚本: " answer || return 0
  [[ "${answer,,}" == yes ]] || return 0
  git -C "$project_root" merge --ff-only "$target_commit" || return 1
  install_helper_scripts || warn "请使用菜单 [22] 重试同步后台脚本。"
  exec env VBM_SKIP_UPDATE_CHECK=1 VBM_PROJECT_ROOT="$project_root" bash "$project_root/run.sh"
}

show_operational_status() {
  local state_dir time_label key
  state_dir=$(dirname -- "$BACKUP_RESULT_FILE")
  printf '主目标：%s\n次目标：%s\n' "${BACKUP_TARGET:-未配置}" "${SECONDARY_TARGET:-none}"
  for key in local-snapshot verified-github verified-webdav decrypt-verified drill-verified; do
    case "$key" in
      local-snapshot) time_label="最近本地快照" ;;
      verified-github) time_label="最近 GitHub 核验" ;;
      verified-webdav) time_label="最近 WebDAV 核验" ;;
      decrypt-verified) time_label="最近解密验证" ;;
      drill-verified) time_label="最近隔离演练" ;;
    esac
    printf '%s：%s\n' "$time_label" "$(date -r "$state_dir/$key" '+%F %T %Z' 2>/dev/null || printf '未记录')"
  done
  if [[ -d "$state_dir/pending" ]]; then
    printf '待上传任务：%s\n' "$(find "$state_dir/pending" -type f -name 'vw-*.tar.gz.age' -printf '.' | wc -c)"
  else
    echo "待上传任务：0"
  fi
  if [[ -d "$state_dir/rejected" ]]; then
    key=$(find "$state_dir/rejected" -type f -name 'vw-*.tar.gz.age' -printf '.' | wc -c)
    if (( key > 0 )); then printf '超出单文件上限、不再重试的备份：%s（请改用 WebDAV 主目标）\n' "$key"; fi
  fi
  if [[ "${BACKUP_TARGET:-}" == github || "${SECONDARY_TARGET:-none}" == github ]]; then
    show_github_capacity
  fi
  if python3 "$STORAGE_TOOL" check-signing >/dev/null 2>&1; then
    echo "备份签名：已配置"
  else
    echo "备份签名：待配置"
  fi
}

# GitHub keeps every committed blob in history, so the repository only grows.
# Report the object store size and warn before the latest backup outgrows the
# single-file limit.
show_github_capacity() {
  local repo="${REPO_DIR:-/opt/vw-github-repo}" kib last_bytes="" limit_bytes result_file
  result_file="${BACKUP_RESULT_FILE:-/var/lib/vaultwarden-backup/last-result.env}"
  if kib=$(vw_git_repo_kib "$repo" 2>/dev/null); then
    printf 'GitHub 备份仓库 Git 对象体积：%s MiB（%s）\n' "$((kib / 1024))" "$repo"
    if (( kib >= 1024 * 1024 )); then
      echo "[注意] 仓库已超过 1 GiB。删除备份不会缩小 Git 历史，请参考手册「GitHub 仓库容量」处理。"
    fi
  else
    echo "GitHub 备份仓库 Git 对象体积：无法读取（本地工作目录不存在：$repo）"
  fi
  if [[ -f "$result_file" && ! -L "$result_file" ]]; then
    last_bytes=$(sed -n 's/^BACKUP_BYTES=\([0-9][0-9]*\)$/\1/p' "$result_file" | head -n 1)
  fi
  limit_bytes=$(( ${MAX_FILE_MIB:-90} * 1024 * 1024 ))
  if [[ "$last_bytes" =~ ^[0-9]+$ ]] && (( last_bytes > 0 )); then
    printf '最近一次密文大小：%s MiB / 单文件上限 %s MiB\n' "$((last_bytes / 1048576))" "${MAX_FILE_MIB:-90}"
    if (( last_bytes * 100 >= limit_bytes * 80 )); then
      echo "[注意] 最近一次备份已达到 GitHub 单文件上限的 80%，超限后将无法上传到 GitHub，建议把主目标切换为 WebDAV。"
    fi
  fi
}

warn_if_helpers_stale() {
  [[ -r "$CONFIG_FILE" && -f "$SCRIPT_DIR/vw-backup.sh" && -f "$SCRIPT_DIR/../run.sh" ]] || return 0
  local source installed module mismatched=()
  check_helper() {
    source="$1"
    installed="$2"
    if [[ ! -f "$source" || ! -f "$installed" ]] || ! cmp -s "$source" "$installed"; then
      mismatched+=("$(basename -- "$source")")
    fi
  }
  check_helper "$SCRIPT_DIR/vw-common.sh" /usr/local/libexec/vw-common.sh
  check_helper "$SCRIPT_DIR/vw-maintenance.sh" /usr/local/libexec/vw-maintenance.sh
  check_helper "$SCRIPT_DIR/vw-backup.sh" "$BACKUP_SCRIPT"
  check_helper "$SCRIPT_DIR/vw-restore-prepare.sh" "$RESTORE_SCRIPT"
  check_helper "$SCRIPT_DIR/vw-storage.py" /usr/local/libexec/vw-storage.py
  check_helper "$SCRIPT_DIR/vw-manifest.py" /usr/local/libexec/vw-manifest.py
  check_helper "$SCRIPT_DIR/vw-archive-check.py" /usr/local/libexec/vw-archive-check.py
  check_helper "$SCRIPT_DIR/vw-diagnose.sh" /usr/local/sbin/vw-diagnose.sh
  check_helper "$SCRIPT_DIR/vw-performance.py" /usr/local/libexec/vw-performance.py
  check_helper "$SCRIPT_DIR/vw-manager.sh" "$MANAGER_SCRIPT"
  for module in ${MANAGER_MODULES[@]+"${MANAGER_MODULES[@]}"}; do
    check_helper "$SCRIPT_DIR/$module" "/usr/local/libexec/$module"
  done
  if ((${#mismatched[@]})); then
    warn "后台脚本与当前源码不同：${mismatched[*]}；请使用菜单 [22] 同步。"
  fi
}
