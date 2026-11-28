#!/usr/bin/env bash
# shellcheck shell=bash
# GitHub: SSH command, deploy key setup and backup repository initialisation.
# Sourced by vw-manager.sh through vbm_source_trusted; relies on its globals and helpers.

make_ssh_command() {
  local key="$1"
  # The configured key path is stored in a root-only config. Avoid user-controlled shell fragments.
  printf -v GIT_SSH_COMMAND 'ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts' "$key"
  export GIT_SSH_COMMAND
}

setup_github_ssh() {
  local key_path="$1" pub_path answer scan_out
  case "$key_path" in
    /root/.ssh/*) ;;
    *) err "为避免误改系统文件，GitHub SSH 私钥必须保存在 /root/.ssh/ 目录下。"; return 1 ;;
  esac
  mkdir -p /root/.ssh "$(dirname -- "$key_path")"
  chmod 700 /root/.ssh "$(dirname -- "$key_path")"
  if [[ ! -f "$key_path" ]]; then
    warn "将生成一把专门访问此备份仓库的 SSH 密钥。"
    if ! ssh-keygen -t ed25519 -C "vaultwarden-backup-manager" -f "$key_path" -N ""; then err "SSH 密钥生成失败。"; return 1; fi
  fi
  chmod 600 "$key_path"
  pub_path="${key_path}.pub"
  if [[ ! -f "$pub_path" ]]; then
    ssh-keygen -y -f "$key_path" > "$pub_path"
    chmod 644 "$pub_path"
  fi
  echo
  echo "下面是需要添加到 GitHub 备份仓库的 SSH 公钥（只复制这一行）："
  cat "$pub_path"
  echo
  warn "GitHub 仓库 → Settings → Deploy keys → Add deploy key。若本机要继续每日备份，请勾选 Allow write access。"
  if [[ ! -f /root/.ssh/known_hosts ]] || ! ssh-keygen -F github.com -f /root/.ssh/known_hosts >/dev/null 2>&1; then
    warn "首次信任 GitHub SSH 主机密钥。更严格的环境应先通过 GitHub 官方公布的指纹核对主机密钥。"
    if confirm_yes "是否使用 ssh-keyscan 获取 github.com 主机公钥并写入 known_hosts？"; then
      scan_out=$(ssh-keyscan -t ed25519 github.com 2>/dev/null || true)
      [[ -n "$scan_out" ]] || { err "未能获取 GitHub 主机密钥。"; return 1; }
      printf '%s\n' "$scan_out" >> /root/.ssh/known_hosts
      chmod 600 /root/.ssh/known_hosts
    else
      err "未配置 known_hosts，无法安全连接 GitHub。"
      return 1
    fi
  fi
  if ! confirm_yes "你是否已经把上面的公钥添加到了正确的 GitHub 备份仓库？"; then
    warn "请先完成 GitHub Deploy Key 添加，再重新运行首次配置。"
    return 1
  fi
}

init_or_clone_backup_repo() {
  local repo_url="$1" branch="$2" repo_dir="$3" ssh_key="$4"
  make_ssh_command "$ssh_key"
  local remote_heads all_heads
  remote_heads=$(git ls-remote --heads "$repo_url" "refs/heads/$branch") || {
    err "无法读取 GitHub 仓库。请检查 SSH Deploy Key、仓库地址和网络。"
    return 1
  }
  all_heads=$(git ls-remote --heads "$repo_url") || return 1
  if [[ -n "$all_heads" && -z "$remote_heads" ]]; then
    err "远程仓库非空，但不存在分支 $branch。请检查 GITHUB_BRANCH 设置。"
    return 1
  fi
  if [[ -d "$repo_dir/.git" ]]; then
    local existing_url
    existing_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
    if [[ "$existing_url" != "$repo_url" ]]; then
      err "本地目录 $repo_dir 已存在 Git 仓库，但 origin 地址不是当前备份仓库。为避免覆盖，停止操作。"
      return 1
    fi
    if [[ -n "$remote_heads" ]]; then
      git -C "$repo_dir" fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch" || return 1
      if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$repo_dir" switch "$branch" >/dev/null 2>&1 || return 1
        git -C "$repo_dir" merge --ff-only "origin/$branch" >/dev/null || {
          err "本地与 GitHub 历史出现分叉。为避免覆盖本地未推送备份，已停止；请先检查 $repo_dir。"
          return 1
        }
      else
        git -C "$repo_dir" switch -c "$branch" --track "origin/$branch" >/dev/null || return 1
      fi
    fi
    return 0
  fi
  if [[ -e "$repo_dir" ]] && [[ -n "$(find "$repo_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    err "本地仓库目录非空但不是可识别的 Git 仓库：$repo_dir。请先检查，不会自动删除。"
    return 1
  fi
  rmdir "$repo_dir" 2>/dev/null || true
  mkdir -p "$(dirname "$repo_dir")"
  if [[ -n "$remote_heads" ]]; then
    info "GitHub 备份仓库已有历史，正在克隆分支 $branch。"
    git clone --branch "$branch" "$repo_url" "$repo_dir" || return 1
  elif [[ -n "$all_heads" ]]; then
    err "远程仓库非空，但不存在分支 $branch。请检查 GITHUB_BRANCH 设置。"
    return 1
  else
    info "GitHub 仓库目前为空，初始化本地 Git 仓库。"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -b "$branch" >/dev/null
    git -C "$repo_dir" remote add origin "$repo_url"
  fi
  git -C "$repo_dir" config user.name "Vaultwarden Backup"
  git -C "$repo_dir" config user.email "vaultwarden-backup@localhost"
}
