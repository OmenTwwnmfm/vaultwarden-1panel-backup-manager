#!/usr/bin/env bash

verify_release_tag() {
  local project_root="$1" tag_object="$2" expected_tag="$3" release_signers="$4"
  git -C "$project_root" -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$release_signers" verify-tag "$tag_object" >/dev/null 2>&1 || return 1
  [[ "$(git -C "$project_root" cat-file -p "$tag_object" | sed -n '3s/^tag //p')" == "$expected_tag" ]] || return 1
  git -C "$project_root" rev-parse "$tag_object^{commit}"
}

release_version_allowed() {
  local current="$1" candidate="$2"
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$(printf '%s\n' "$current" "$candidate" | sort -Vr | sed -n '1p')" == "$candidate" ]]
}

check_for_project_updates() {
  [[ "${VBM_SKIP_UPDATE_CHECK:-0}" == 1 ]] && return 0
  local project_root="${VBM_PROJECT_ROOT:-$(readlink -f -- "$SCRIPT_DIR/..")}"
  local channel stable_tag tag_object branch target_commit remote_version current_commit candidate answer
  local release_signers="/etc/vaultwarden-release-signers"
  [[ -d "$project_root/.git" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0
  channel=$( (load_config >/dev/null 2>&1 || true; printf '%s' "${UPDATE_CHANNEL:-stable}") )
  if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
    warn "项目有本地修改，跳过更新。"
    return 0
  fi
  case "$channel" in
    stable)
      if [[ ! -f "$release_signers" || -L "$release_signers" || "$(stat -c %u -- "$release_signers")" != 0 || -n "$(find "$release_signers" -maxdepth 0 -perm /022 -print)" ]]; then
        info "稳定版更新需要独立取得可信发布者公钥，并配置 $release_signers。"
        return 0
      fi
      candidate=$(timeout 20s git -C "$project_root" ls-remote --tags --refs origin 'v*') || { warn "无法读取稳定版标签。"; return 0; }
      stable_tag=$(printf '%s\n' "$candidate" | awk '$2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ {sub("^refs/tags/","",$2); print $2}' | sort -Vr | sed -n '1p')
      [[ -n "$stable_tag" ]] || { info "未找到稳定版标签。"; return 0; }
      timeout 25s git -C "$project_root" fetch --no-tags origin "refs/tags/$stable_tag" || return 1
      tag_object=$(git -C "$project_root" rev-parse FETCH_HEAD) || return 1
      if ! target_commit=$(verify_release_tag "$project_root" "$tag_object" "$stable_tag" "$release_signers"); then
        warn "稳定版 $stable_tag 未通过可信发布者验签。"
        return 1
      fi
      ;;
    main)
      warn "main 渠道跟踪开发分支，跳过发布标签验签。"
      branch=main
      timeout 20s git -C "$project_root" fetch --no-tags origin "$branch" || return 1
      target_commit=$(git -C "$project_root" rev-parse FETCH_HEAD) || return 1
      ;;
    *) err "UPDATE_CHANNEL 只能为 stable 或 main。"; return 1 ;;
  esac
  current_commit=$(git -C "$project_root" rev-parse HEAD) || return 1
  [[ "$current_commit" != "$target_commit" ]] || { ok "源码已经是当前渠道的最新版。"; return 0; }
  remote_version=$(git -C "$project_root" show "$target_commit:scripts/vw-manager.sh" | sed -n 's/^VERSION="\([^"]*\)"$/\1/p') || return 1
  if ! release_version_allowed "$VERSION" "$remote_version" ||
      [[ "$channel" == stable && "$stable_tag" != "v$remote_version" ]]; then
    warn "目标版本无效或低于当前版本，更新停止。"
    return 1
  fi
  git -C "$project_root" merge-base --is-ancestor "$current_commit" "$target_commit" || { warn "更新需要快进，当前提交不在目标版本历史中。"; return 1; }
  printf '当前 v%s，目标 v%s，渠道 %s\n' "$VERSION" "$remote_version" "$channel"
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
  if python3 "$STORAGE_TOOL" check-signing >/dev/null 2>&1; then
    echo "备份签名：已配置"
  else
    echo "备份签名：待配置"
  fi
}

warn_if_helpers_stale() {
  [[ -r "$CONFIG_FILE" && -f "$SCRIPT_DIR/vw-backup.sh" ]] || return 0
  if ! cmp -s "$SCRIPT_DIR/vw-backup.sh" "$BACKUP_SCRIPT" ||
     ! cmp -s "$SCRIPT_DIR/vw-storage.py" /usr/local/libexec/vw-storage.py ||
     ! cmp -s "$SCRIPT_DIR/vw-common.sh" /usr/local/libexec/vw-common.sh ||
     ! cmp -s "$SCRIPT_DIR/vw-maintenance.sh" /usr/local/libexec/vw-maintenance.sh ||
     ! cmp -s "$SCRIPT_DIR/vw-restore-prepare.sh" "$RESTORE_SCRIPT"; then
    warn "后台脚本与当前源码不同，请使用菜单 [22] 同步。"
  fi
}
