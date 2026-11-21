#!/usr/bin/env bash
# Interactive manager for 1Panel App Store Vaultwarden (SQLite, /data mount).
# This script does NOT install Docker, Vaultwarden, HTTPS, or reverse proxy.
set -Eeuo pipefail
umask 077

VERSION="1.4.2"
CONFIG_FILE="/etc/vaultwarden-backup.conf"
BACKUP_SCRIPT="/usr/local/sbin/vw-backup.sh"
RESTORE_SCRIPT="/usr/local/sbin/vw-restore-prepare.sh"
MANAGER_SCRIPT="/usr/local/sbin/vw-manager.sh"
LOG_FILE="/var/log/vaultwarden-backup.log"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="$SCRIPT_DIR/vw-common.sh"
if [[ ! -f "$COMMON_LIB" ]]; then COMMON_LIB="/usr/local/libexec/vw-common.sh"; fi
if [[ -f "$COMMON_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$COMMON_LIB"
else
  printf '[错误] 找不到共享检测库：%s\n' "$COMMON_LIB" >&2
  exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info() { printf "${BLUE}[信息]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[完成]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[注意]${NC} %s\n" "$*"; }
err() { printf "${RED}[错误]${NC} %s\n" "$*" >&2; }
pause() { read -r -p $'\n按 Enter 返回菜单... ' _ || true; }

confirm_yes() {
  local prompt="$1" answer
  printf '\n%s\n' "$prompt"
  read -r -p "输入 yes 继续（其他输入均取消）: " answer || true
  [[ "${answer,,}" == "yes" ]]
}
confirm_yes_upper() {
  # Keep the historical function name for compatibility, but accept YES in
  # any letter case. This is case-insensitive, not a single-key confirmation.
  local prompt="$1" answer
  printf '\n%s\n' "$prompt"
  read -r -p "这是有风险的操作。输入 yes 确认（大小写不敏感，例如 yes / YES / Yes）: " answer || true
  [[ "${answer,,}" == "yes" ]]
}
read_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value || true
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
    err "没有找到 docker 命令。请先确认 1Panel 已安装并正常管理 Docker。"
    return 1
  fi
}

install_dependencies() {
  local missing=() pkg
  for cmd in age age-keygen git ssh-keygen ssh-keyscan sha256sum tar gzip flock sqlite3 python3 logrotate; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} == 0)); then
    ok "备份所需工具已安装。"
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    err "缺少工具：${missing[*]}；当前系统没有 apt-get，请手动安装。"
    return 1
  fi
  warn "需要安装备份工具：age、git、openssh-client、tar、gzip、util-linux 等。不会安装或修改 Docker。"
  confirm_yes "是否使用 apt 安装缺少的备份工具？" || { warn "已取消。"; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update; then err "apt-get update 失败，请检查 VPS 软件源和网络。"; return 1; fi
  if ! apt-get install -y age git openssh-client coreutils tar gzip util-linux findutils sqlite3 python3 logrotate; then err "依赖安装失败。"; return 1; fi
  ok "备份工具安装完成。"
}

list_vaultwarden_containers() {
  require_docker || return 1
  local -a rows=() matches=()
  local line name image status lower
  mapfile -t rows < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
  for line in "${rows[@]}"; do
    IFS='|' read -r name image status <<< "$line"
    lower="${name,,} ${image,,}"
    if [[ "$lower" == *vaultwarden* ]]; then
      matches+=("$line")
    fi
  done
  if ((${#matches[@]} == 0)); then
    err "没有发现名称或镜像中包含 vaultwarden 的容器。请先在 1Panel 应用商店确认 Vaultwarden 已安装。"
    return 1
  fi
  printf '\n发现以下 Vaultwarden 候选容器：\n'
  local i=1
  for line in "${matches[@]}"; do
    IFS='|' read -r name image status <<< "$line"
    printf '  %d) 容器：%s\n     镜像：%s\n     状态：%s\n' "$i" "$name" "$image" "$status"
    ((i+=1))
  done
  local choice
  if ((${#matches[@]} == 1)); then
    choice=1
    info "只发现一个候选容器，默认选择它。"
  else
    read -r -p "请输入要管理的容器编号: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#matches[@]})) || { err "编号无效。"; return 1; }
  fi
  IFS='|' read -r DETECTED_CONTAINER DETECTED_IMAGE DETECTED_STATUS <<< "${matches[$((choice-1))]}"
  export DETECTED_CONTAINER DETECTED_IMAGE DETECTED_STATUS
  ok "已选择容器：$DETECTED_CONTAINER"
}

inspect_data_mount() {
  local container="$1" source
  source=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{"\n"}}{{end}}{{end}}' | sed '/^[[:space:]]*$/d')
  if [[ -z "$source" ]]; then
    err "容器 $container 没有发现挂载到 /data 的主机目录。"
    echo "请先运行 docker inspect '$container' 查看全部挂载，不能猜测数据路径。"
    return 1
  fi
  if [[ "$source" == *$'\n'* ]]; then
    err "检测到多个 /data 挂载记录，无法安全自动判断。"
    return 1
  fi
  if [[ ! -d "$source" ]]; then
    err "检测到的数据目录不存在：$source"
    return 1
  fi
  if [[ ! -f "$source/db.sqlite3" ]]; then
    err "数据目录中没有 db.sqlite3：$source"
    warn "当前管理器只支持 SQLite 版 Vaultwarden。为避免错误备份，不会继续。"
    return 1
  fi
  DETECTED_DATA_DIR="$(readlink -f -- "$source")"
  case "$DETECTED_DATA_DIR" in
    /|/var|/var/lib|/var/lib/docker|/opt|/root|/home|/etc|/usr)
      err "检测到的 /data 主机路径过于宽泛：$DETECTED_DATA_DIR。为防止误移动系统目录，拒绝继续。"
      return 1
      ;;
  esac
  export DETECTED_DATA_DIR
  ok "已确认 /data 主机目录：$DETECTED_DATA_DIR"
  echo "数据库文件：$(du -h "$DETECTED_DATA_DIR/db.sqlite3" | awk '{print $1}')"
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "尚未配置。请先选择菜单 1「首次配置 / 重新检测」。"
    return 1
  fi
  # Config is created by this root-only manager and must not be writable by other users.
  if [[ "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo 777)" != "600" ]]; then
    warn "$CONFIG_FILE 权限不是 600，正在收紧权限。"
    chmod 600 "$CONFIG_FILE"
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  # Backward-compatible defaults for configurations created by v1.2.x.
  SYSTEMD_TIME="${SYSTEMD_TIME:-*-*-* 05:20:00}"
  BACKUP_FREQUENCY="${BACKUP_FREQUENCY:-daily}"
  MIN_FREE_MB="${MIN_FREE_MB:-512}"
  GIT_PUSH_RETRIES="${GIT_PUSH_RETRIES:-3}"
  GIT_RETRY_DELAY="${GIT_RETRY_DELAY:-15}"
  NOTIFY_METHOD="${NOTIFY_METHOD:-none}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
  NTFY_URL="${NTFY_URL:-}"
  NTFY_TOKEN="${NTFY_TOKEN:-}"
  WEBHOOK_URL="${WEBHOOK_URL:-}"
  NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-true}"
  NOTIFY_ON_FAILURE="${NOTIFY_ON_FAILURE:-true}"
}

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
    if ! ssh-keygen -t ed25519 -C "vaultwarden-1panel-backup" -f "$key_path" -N ""; then err "SSH 密钥生成失败。"; return 1; fi
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

write_config() {
  local container="$1" data_dir="$2" age_recipient="$3" github_repo="$4" branch="$5" ssh_key="$6" backup_dir="$7" repo_dir="$8" retention="$9" max_mib="${10}" identity_default="${11}"
  local tmp
  tmp=$(mktemp)
  {
    printf 'CONTAINER=%q\n' "$container"
    printf 'DATA_DIR=%q\n' "$data_dir"
    printf 'AGE_RECIPIENT=%q\n' "$age_recipient"
    printf 'GITHUB_REPO=%q\n' "$github_repo"
    printf 'GITHUB_BRANCH=%q\n' "$branch"
    printf 'GITHUB_SSH_KEY=%q\n' "$ssh_key"
    printf 'BACKUP_DIR=%q\n' "$backup_dir"
    printf 'REPO_DIR=%q\n' "$repo_dir"
    printf 'RETENTION_DAYS=%q\n' "$retention"
    printf 'MAX_FILE_MIB=%q\n' "$max_mib"
    printf 'AGE_IDENTITY_DEFAULT=%q\n' "$identity_default"
    printf 'SYSTEMD_TIME=%q\n' "${SYSTEMD_TIME:-*-*-* 05:20:00}"
    printf 'BACKUP_FREQUENCY=%q\n' "${BACKUP_FREQUENCY:-daily}"
    printf 'MIN_FREE_MB=%q\n' "${MIN_FREE_MB:-512}"
    printf 'GIT_PUSH_RETRIES=%q\n' "${GIT_PUSH_RETRIES:-3}"
    printf 'GIT_RETRY_DELAY=%q\n' "${GIT_RETRY_DELAY:-15}"
    printf 'NOTIFY_METHOD=%q\n' "${NOTIFY_METHOD:-none}"
    printf 'TELEGRAM_BOT_TOKEN=%q\n' "${TELEGRAM_BOT_TOKEN:-}"
    printf 'TELEGRAM_CHAT_ID=%q\n' "${TELEGRAM_CHAT_ID:-}"
    printf 'NTFY_URL=%q\n' "${NTFY_URL:-}"
    printf 'NTFY_TOKEN=%q\n' "${NTFY_TOKEN:-}"
    printf 'WEBHOOK_URL=%q\n' "${WEBHOOK_URL:-}"
    printf 'NOTIFY_ON_SUCCESS=%q\n' "${NOTIFY_ON_SUCCESS:-true}"
    printf 'NOTIFY_ON_FAILURE=%q\n' "${NOTIFY_ON_FAILURE:-true}"
  } > "$tmp"
  install -o root -g root -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

install_helper_scripts() {
  local source_dir="$SCRIPT_DIR"
  [[ -f "$source_dir/vw-manager.sh" && -f "$source_dir/vw-common.sh" && -f "$source_dir/vw-backup.sh" && -f "$source_dir/vw-restore-prepare.sh" && -f "$source_dir/vw-manifest.py" && -f "$source_dir/vw-diagnose.sh" && -f "$source_dir/vw-performance.py" && -f "$source_dir/vbm-launcher.sh" ]] || {
    err "项目脚本不完整，缺少 vw-common.sh / vw-backup.sh / vw-restore-prepare.sh。"
    return 1
  }
  install -d -o root -g root -m 755 /usr/local/libexec /usr/local/sbin
  install -o root -g root -m 644 "$source_dir/vw-common.sh" /usr/local/libexec/vw-common.sh || return 1
  install -o root -g root -m 700 "$source_dir/vw-backup.sh" "$BACKUP_SCRIPT" || return 1
  install -o root -g root -m 700 "$source_dir/vw-restore-prepare.sh" "$RESTORE_SCRIPT" || return 1
  install -o root -g root -m 755 "$source_dir/vw-manifest.py" /usr/local/libexec/vw-manifest.py || return 1
  install -o root -g root -m 700 "$source_dir/vw-diagnose.sh" /usr/local/sbin/vw-diagnose.sh || return 1
  install -o root -g root -m 755 "$source_dir/vw-performance.py" /usr/local/libexec/vw-performance.py || return 1
  install -o root -g root -m 700 "$source_dir/vw-manager.sh" "$MANAGER_SCRIPT" || return 1
  local project_root launcher_tmp
  project_root=$(readlink -f -- "$source_dir/..")
  [[ -f "$project_root/run.sh" ]] || { err "找不到项目 run.sh，无法安装全局命令 vbm。"; return 1; }
  install -d -o root -g root -m 755 /usr/local/bin
  launcher_tmp=$(mktemp)
  python3 - "$source_dir/vbm-launcher.sh" "$launcher_tmp" "$project_root/run.sh" <<'PYVBM'
from pathlib import Path
import shlex, sys
source, target, runner = sys.argv[1:]
content = Path(source).read_text(encoding="utf-8")
content = content.replace("__VBM_PROJECT_RUNNER__", shlex.quote(runner))
Path(target).write_text(content, encoding="utf-8")
PYVBM
  install -o root -g root -m 755 "$launcher_tmp" /usr/local/bin/vbm
  rm -f "$launcher_tmp"
  if [[ ! -x /usr/local/bin/vbm ]]; then err "全局命令 vbm 安装后不可执行。"; return 1; fi
  case ":${PATH}:" in
    *:/usr/local/bin:*) ;;
    *) if [[ ":${PATH}:" == *:/usr/bin:* && ! -e /usr/bin/vbm ]]; then ln -s /usr/local/bin/vbm /usr/bin/vbm; fi ;;
  esac
  install -d -o root -g root -m 755 /etc/logrotate.d
  install -o root -g root -m 644 "$(dirname "$source_dir")/logrotate-vaultwarden-backup" /etc/logrotate.d/vaultwarden-backup || return 1
  ok "后台脚本已安装/更新："
  echo "  /usr/local/libexec/vw-common.sh"
  echo "  /usr/local/libexec/vw-manifest.py"
  echo "  $BACKUP_SCRIPT"
  echo "  $RESTORE_SCRIPT"
  echo "  /usr/local/sbin/vw-diagnose.sh"
  echo "  /usr/local/libexec/vw-performance.py"
  echo "  $MANAGER_SCRIPT"
  echo "  /usr/local/bin/vbm（全局启动命令）"
  echo "  /etc/logrotate.d/vaultwarden-backup"
}

update_installed_scripts() {
  [[ -f "$CONFIG_FILE" ]] || { err "尚未完成首次配置，请先运行菜单 1。"; return 1; }
  echo "将更新管理器、备份/恢复/诊断/性能工具、全局 vbm 命令及公共库，不会修改 /etc/vaultwarden-backup.conf、age 公钥、SSH 密钥或 GitHub 仓库。若 systemd timer 已安装，timer 文件会保留。"
  confirm_yes_upper "确认安装当前项目目录中的新版脚本？" || { warn "已取消。"; return 0; }
  install_helper_scripts || { err "脚本更新失败。"; return 1; }
  ok "更新完成。全局命令 vbm 已安装/更新；下一次备份将自动重新检测 1Panel 当前容器名称及 /data 主机目录。"
  pause
}

configure_wizard() {
  require_docker || return 1
  install_dependencies || return 1
  echo
  echo "========== 第 1 步：检测 Vaultwarden 容器 =========="
  list_vaultwarden_containers || return 1
  inspect_data_mount "$DETECTED_CONTAINER" || return 1

  echo
  echo "========== 第 2 步：配置 GitHub 备份仓库 =========="
  local github_repo branch ssh_key age_recipient identity_default backup_dir repo_dir retention max_mib
  read -r -p "GitHub 专用 Private 备份仓库 SSH 地址（git@github.com:用户名/vaultwarden-backup.git）: " github_repo
  [[ "$github_repo" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] || { err "仓库地址格式不正确。请使用 git@github.com:用户名/仓库名.git"; return 1; }
  branch=$(read_default "GitHub 分支名" "main")
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    err "Git 分支名不合法：$branch"
    return 1
  fi
  ssh_key=$(read_default "GitHub SSH 私钥路径" "/root/.ssh/vw_github_backup")
  setup_github_ssh "$ssh_key" || return 1

  echo
  echo "========== 第 3 步：配置 age 加密公钥 =========="
  echo "你可以使用以前生成的公钥，或者创建一套新的 age 密钥。若是恢复旧备份/迁移 VPS，必须使用原来的 age 公钥和对应私钥，不能新建替代。"
  local age_choice
  read -r -p "是否已经有原来的 age 公钥？输入 y 使用已有公钥，输入 n 新建密钥 [y/n]: " age_choice
  case "${age_choice,,}" in
    y)
      read -r -p "请输入原来的 age 公钥（age1...）: " age_recipient
      [[ "$age_recipient" =~ ^age1[[:alnum:]]+$ ]] || { err "公钥格式看起来不正确。"; return 1; }
      identity_default=$(read_default "恢复时私钥文件默认路径（可之后重新输入）" "/root/vw-age-identity.txt")
      ;;
    n)
      identity_default=$(read_default "新 age 私钥文件保存路径" "/root/vw-age-identity.txt")
      if [[ -e "$identity_default" ]]; then
        err "文件已存在，为防止覆盖旧私钥，取消生成：$identity_default"
        return 1
      fi
      mkdir -p "$(dirname -- "$identity_default")"
      if ! age-keygen -o "$identity_default"; then err "age 密钥生成失败。"; return 1; fi
      chmod 600 "$identity_default"
      age_recipient=$(age-keygen -y "$identity_default") || { err "无法读取刚生成的 age 私钥。"; return 1; }
      echo
      ok "已生成 age 密钥对。请立即将完整私钥文件复制到至少两份离线安全位置，并在离线设备上用 age-keygen -y 验证公钥一致。"
      echo "公钥（可放入服务器配置）：$age_recipient"
      echo "私钥文件位置：$identity_default"
      if ! confirm_yes "你是否已将私钥离线保存并验证？（私钥丢失会导致备份无法恢复）"; then
        warn "配置暂不完成。先安全保存私钥，再重新运行本向导并选择已有公钥。"
        return 1
      fi
      ;;
    *) err "请输入 y 或 n。"; return 1 ;;
  esac

  echo
  echo "========== 第 4 步：设置本地目录与保留策略 =========="
  backup_dir=$(read_default "本地加密备份目录" "/var/backups/vaultwarden")
  repo_dir=$(read_default "GitHub 本地仓库目录" "/opt/vw-github-repo")
  retention=$(read_default "本地/仓库当前文件保留天数" "30")
  max_mib=$(read_default "单个 GitHub 文件大小上限 MiB（建议不超过 90）" "90")
  [[ "$retention" =~ ^[0-9]+$ ]] && ((retention >= 1)) || { err "保留天数必须是正整数。"; return 1; }
  [[ "$max_mib" =~ ^[0-9]+$ ]] && ((max_mib >= 1 && max_mib <= 95)) || { err "文件限制必须为 1 到 95 MiB。"; return 1; }
  local data_canon backup_canon repo_canon
  data_canon=$(readlink -f -- "$DETECTED_DATA_DIR")
  backup_canon=$(readlink -m -- "$backup_dir")
  repo_canon=$(readlink -m -- "$repo_dir")
  for candidate_dir in "$backup_canon" "$repo_canon"; do
    case "$candidate_dir" in
      /|/var|/var/lib|/var/lib/docker|/opt|/root|/home|/etc|/usr)
        err "备份目录或 Git 工作目录过于宽泛：$candidate_dir。请选择专用子目录。"
        return 1
        ;;
    esac
  done
  if paths_overlap "$data_canon" "$backup_canon" || paths_overlap "$data_canon" "$repo_canon"; then
    err "本地备份目录/Git 工作目录不能与 Vaultwarden 数据目录相同、互相嵌套或覆盖。请重新选择独立目录。"
    return 1
  fi
  if paths_overlap "$backup_canon" "$repo_canon"; then
    err "本地加密备份目录和 Git 工作目录必须相互独立。请重新选择目录。"
    return 1
  fi

  echo
  echo "========== 配置摘要 =========="
  printf '容器名称：%s\n镜像：%s\n容器状态：%s\n主机数据目录：%s\nage 公钥：%s\nGitHub 仓库：%s\n分支：%s\nSSH 私钥：%s\n本地备份目录：%s\nGit 工作目录：%s\n保留天数：%s\n' \
    "$DETECTED_CONTAINER" "$DETECTED_IMAGE" "$DETECTED_STATUS" "$DETECTED_DATA_DIR" "$age_recipient" "$github_repo" "$branch" "$ssh_key" "$backup_dir" "$repo_dir" "$retention"
  confirm_yes_upper "请确认上述容器和数据目录都是正确的。脚本后续只会操作所显示的 Vaultwarden 容器与 /data 数据目录。" || { warn "已取消。"; return 1; }

  write_config "$DETECTED_CONTAINER" "$DETECTED_DATA_DIR" "$age_recipient" "$github_repo" "$branch" "$ssh_key" "$backup_dir" "$repo_dir" "$retention" "$max_mib" "$identity_default"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  init_or_clone_backup_repo "$github_repo" "$branch" "$repo_dir" "$ssh_key" || return 1

  install_helper_scripts || { err "后台脚本安装失败。"; return 1; }
  ok "配置已保存至 $CONFIG_FILE（权限 600），后台脚本已安装。"
  echo
  if [[ -f "$identity_default" ]]; then
    warn "age 私钥目前仍保存在本机：$identity_default。备份和定时任务只需要 age 公钥。"
    echo "请确认离线副本至少两份且已验证可读；确认后建议从 VPS 删除这份私钥。"
    echo "将来恢复时，再把离线私钥临时复制到服务器，并在菜单 3 中填写路径。"
  fi
  warn "下一步先选择「立即备份并推送」完成测试，然后选择菜单 9 安装 systemd 自动备份（默认每天 05:20，不依赖 1Panel 计划任务）。"
  pause
}

check_configuration() {
  require_docker || return 1
  load_config || return 1
  echo "========== 配置检查 =========="
  printf '配置中记录的容器：%s\n配置中记录的数据目录：%s\n' "$CONTAINER" "$DATA_DIR"
  if ! vw_find_target "$CONTAINER" "$DATA_DIR" true; then
    err "无法自动确认唯一的运行中 Vaultwarden 容器。请运行菜单 1 重新选择。"
    return 1
  fi
  if [[ "$CONTAINER" != "$VW_DETECTED_CONTAINER" || "$(readlink -f "$DATA_DIR")" != "$VW_DETECTED_DATA_DIR" ]]; then
    warn "检测到 1Panel 可能重建过容器，正在更新记录。"
    CONTAINER="$VW_DETECTED_CONTAINER"
    DATA_DIR="$VW_DETECTED_DATA_DIR"
    write_config "$CONTAINER" "$DATA_DIR" "$AGE_RECIPIENT" "$GITHUB_REPO" "$GITHUB_BRANCH" "$GITHUB_SSH_KEY" "$BACKUP_DIR" "$REPO_DIR" "$RETENTION_DAYS" "$MAX_FILE_MIB" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}"
  fi
  printf '当前容器：%s\n镜像：%s\n状态：%s\n/data 主机目录：%s\n' \
    "$VW_DETECTED_CONTAINER" "$VW_DETECTED_IMAGE" "$VW_DETECTED_STATUS" "$VW_DETECTED_DATA_DIR"
  [[ -s "$DATA_DIR/db.sqlite3" ]] || { err "db.sqlite3 不存在或大小为 0。"; return 1; }
  [[ "$AGE_RECIPIENT" == age1* ]] || { err "age 公钥格式错误。"; return 1; }
  [[ -f "$GITHUB_SSH_KEY" ]] || { err "SSH 私钥不存在：$GITHUB_SSH_KEY"; return 1; }
  printf '数据库大小：%s\n' "$(du -h "$DATA_DIR/db.sqlite3" | awk '{print $1}')"
  printf '整个 /data 大小：%s\n' "$(du -sh "$DATA_DIR" | awk '{print $1}')"
  printf '数据目录剩余磁盘：%s\n' "$(df -h "$DATA_DIR" | awk 'NR==2 {print $4}')"
  ok "本地数据路径及容器检查通过。"
  make_ssh_command "$GITHUB_SSH_KEY"
  if git ls-remote "$GITHUB_REPO" HEAD >/dev/null; then ok "GitHub SSH 仓库读取连接正常。"; else err "GitHub 仓库连接失败，请检查 Deploy Key 与仓库地址。"; return 1; fi
  pause
}

run_backup_now() {
  load_config || return 1
  # Interactive/manual backup should execute the worker from the currently
  # checked-out project, not a possibly stale copy installed by an older menu
  # release. systemd continues to use /usr/local/sbin/vw-backup.sh, which is
  # synchronized by menu 07 / the startup updater.
  local worker="$BACKUP_SCRIPT" common_lib="$COMMON_LIB" manifest_tool="/usr/local/libexec/vw-manifest.py"
  [[ -f "$SCRIPT_DIR/vw-backup.sh" ]] && worker="$SCRIPT_DIR/vw-backup.sh"
  [[ -f "$SCRIPT_DIR/vw-common.sh" ]] && common_lib="$SCRIPT_DIR/vw-common.sh"
  [[ -f "$SCRIPT_DIR/vw-manifest.py" ]] && manifest_tool="$SCRIPT_DIR/vw-manifest.py"
  [[ -f "$worker" ]] || { err "找不到备份脚本：$worker。请先运行菜单 07 更新后台脚本。"; return 1; }
  echo "将执行：自动重新检测当前 Vaultwarden 容器与 /data 挂载 → 停止服务 → 完整备份并加密 → 启动服务 → 推送 GitHub。"
  echo "上次记录容器：$CONTAINER"
  echo "上次记录数据目录：$DATA_DIR"
  echo "本次手动备份脚本：$worker"
  echo "性能记录文件：/var/lib/vaultwarden-backup/performance.tsv"
  echo "如果 1Panel 重建过容器，后台脚本会优先按原数据目录重新匹配，并将新容器名写回配置。"
  if ! confirm_yes_upper "此操作会使 Vaultwarden 短暂不可用。确认立即备份？"; then warn "已取消。"; return 0; fi
  local rc=0
  if VW_COMMON_LIB="$common_lib" VW_MANIFEST_TOOL="$manifest_tool" VW_PERF_FILE="/var/lib/vaultwarden-backup/performance.tsv" bash "$worker"; then rc=0; else rc=$?; fi
  if ((rc == 0)); then ok "备份脚本执行完成。"; else err "备份执行失败，先查看日志：$LOG_FILE"; fi
  pause
  return "$rc"
}

clone_for_restore() {
  local url="$1" branch="$2" dest="$3" key="$4"
  make_ssh_command "$key"
  if [[ -e "$dest" ]]; then rm -rf -- "$dest"; fi
  git clone --quiet --branch "$branch" "$url" "$dest"
}

restore_from_github() (
  # Run restore in a subshell so decrypted staging data is removed even if the
  # user interrupts the operation or an unexpected command fails.
  local temp_root="" staging="" container="" stopped_by_script=0 data_change_started=0
  cleanup_restore() {
    local restore_rc=$?
    if [[ "${stopped_by_script:-0}" == "1" && -n "${container:-}" ]]; then
      if [[ "${data_change_started:-0}" == "1" ]]; then
        echo "严重提醒：恢复过程中断，数据目录可能处于恢复中间状态。为避免使用不完整数据，容器保持停止。" >&2
        echo "使用原 age 私钥和回滚文件完成恢复前，不要在 1Panel 中启动该容器。" >&2
      elif docker start "$container" >/dev/null 2>&1; then
        echo "安全清理：已尝试重新启动 Vaultwarden 容器：$container"
      else
        echo "严重提醒：自动清理时无法启动 Vaultwarden。请进入 1Panel 手动启动：$container" >&2
      fi
    fi
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
  local repo_tmp identity archive choice container_state data_dir rollback_archive timestamp restore_ssh_key identity_pub start_choice
  mkdir -p /run/lock
  exec 8>"/run/lock/vaultwarden-backup.lock"
  if ! flock -n 8; then
    err "检测到另一个备份/恢复操作正在运行。请等它结束后再试。"
    return 1
  fi
  temp_root=$(mktemp -d /var/tmp/vw-github-restore.XXXXXX)
  chmod 700 "$temp_root"
  repo_tmp="$temp_root/repository"
  timestamp=$(date '%Y%m%d-%H%M%S')
  vw_perf_init restore "$timestamp-$$"
  vw_perf_stage_begin "github_clone_and_list"

  echo "========== 第 1 步：从 GitHub 获取备份列表 =========="
  restore_ssh_key=$(read_default "读取 GitHub 私有仓库的 SSH 私钥路径" "$GITHUB_SSH_KEY")
  [[ -f "$restore_ssh_key" ]] || { err "SSH 私钥不存在：$restore_ssh_key"; rm -rf -- "$temp_root"; return 1; }
  info "正在读取 GitHub 备份仓库，不会修改远端内容。"
  if ! clone_for_restore "$GITHUB_REPO" "$GITHUB_BRANCH" "$repo_tmp" "$restore_ssh_key"; then
    err "克隆 GitHub 仓库失败。确认仓库中已有备份、Deploy Key 有读取权限。"
    rm -rf -- "$temp_root"
    return 1
  fi
  vw_perf_stage_end success

  local -a archives=()
  mapfile -t archives < <(find "$repo_tmp" -maxdepth 1 -type f -name 'vw-*.tar.gz.age' -printf '%f\n' | sort -r)
  if ((${#archives[@]} == 0)); then err "仓库当前分支没有找到 vw-*.tar.gz.age 备份文件。"; rm -rf -- "$temp_root"; return 1; fi
  echo "可恢复的备份（按时间从新到旧）："
  local i
  for i in "${!archives[@]}"; do printf '  %d) %s (%s)\n' "$((i+1))" "${archives[$i]}" "$(du -h "$repo_tmp/${archives[$i]}" | awk '{print $1}')"; done
  read -r -p "请输入要恢复的备份编号: " choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#archives[@]})); then
    err "编号无效。"; rm -rf -- "$temp_root"; return 1
  fi
  archive="$repo_tmp/${archives[$((choice-1))]}"
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
  timestamp=$(date '+%Y%m%d-%H%M%S')
  staging="/var/lib/vaultwarden-restore-staging-$timestamp"
  if [[ -e "$staging" ]]; then err "暂存目录已存在：$staging"; rm -rf -- "$temp_root"; return 1; fi
  vw_perf_stage_begin "restore_decrypt_validate"
  if ! bash "$RESTORE_SCRIPT" "$archive" "$identity" "$staging"; then
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
  timestamp=$(date '+%Y%m%d-%H%M%S')
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  rollback_archive="$BACKUP_DIR/pre-restore-${timestamp}.tar.gz.age"
  if [[ -e "$rollback_archive" ]]; then err "恢复前快照文件已存在：$rollback_archive"; return 1; fi
  vw_perf_stage_end success

  echo
  printf '选中的备份：%s\n目标容器：%s\n当前容器状态：%s\n将恢复到的数据目录：%s\n当前数据加密留存到：%s\n' \
    "$(basename "$archive")" "$container" "$container_state" "$data_dir" "$rollback_archive"
  warn "恢复会替换 /data 目录内的全部内容。为兼容 Docker 命名卷，不会移动挂载点本身；脚本会先用 age 公钥把当前数据加密保存到本地回滚文件。"
  if ! confirm_yes_upper "请再次核对容器和路径。确认将所选 GitHub 备份恢复到该 Vaultwarden 实例？"; then
    warn "已取消。暂存解密数据将被清理，原数据保持不变。"
    return 0
  fi

  vw_perf_stage_begin "pre_restore_rollback_snapshot"
  local was_running=0 rollback_ok=0
  [[ "$container_state" == "running" ]] && was_running=1
  if ((was_running == 1)); then
    info "正在停止 Vaultwarden 容器：$container"
    if ! docker stop --time 30 "$container" >/dev/null; then
      err "容器停止失败，未修改数据目录。"
      return 1
    fi
    stopped_by_script=1
  fi

  # Create an encrypted pre-restore snapshot before changing anything. The original
  # age identity supplied above can decrypt it if the restore must be rolled back.
  echo "正在加密保存当前 /data，以便恢复失败时回滚..."
  if ! tar --numeric-owner -czpf - -C "$data_dir" . | age -r "$AGE_RECIPIENT" -o "$rollback_archive"; then
    err "创建恢复前加密快照失败，当前数据目录尚未修改。"
    rm -f -- "$rollback_archive"
    if ((was_running == 1)); then
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 中手动启动容器。"; fi
    fi
    return 1
  fi
  if [[ ! -s "$rollback_archive" ]]; then
    err "恢复前加密快照为空，当前数据目录尚未修改。"
    rm -f -- "$rollback_archive"
    if ((was_running == 1)); then
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 中手动启动容器。"; fi
    fi
    return 1
  fi
  (cd "$BACKUP_DIR" && sha256sum "$(basename "$rollback_archive")" > "$(basename "$rollback_archive").sha256")
  if ! (cd "$BACKUP_DIR" && sha256sum -c "$(basename "$rollback_archive").sha256") || ! age -d -i "$identity" "$rollback_archive" | tar -tzf - >/dev/null; then
    err "恢复前回滚快照校验失败，生产数据尚未替换。"
    rm -f -- "$rollback_archive" "$rollback_archive.sha256"
    if ((was_running == 1)); then
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 中手动启动容器。"; fi
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
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 中手动启动容器。"; fi
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
      if docker start "$container" >/dev/null 2>&1; then stopped_by_script=0; else warn "请在 1Panel 中手动启动容器。"; fi
    fi
    return 1
  fi
  data_change_started=0
  vw_perf_stage_end success
  vw_perf_stage_begin "container_start_health_check"

  ok "数据恢复文件已复制完成。原数据的加密回滚快照保留在：$rollback_archive"
  start_choice="yes"
  if ((was_running == 0)); then
    start_choice=$(read_default "原容器此前已停止。是否现在启动恢复后的 Vaultwarden？输入 yes 启动，no 保持停止" "yes")
  else
    start_choice="yes"
  fi
  if [[ "${start_choice,,}" == "yes" ]]; then
    if docker start "$container" >/dev/null && vw_wait_healthy "$container" 30 2; then
      stopped_by_script=0
      ok "Vaultwarden 已启动并达到 running/healthy 状态。"
    else
      err "恢复后的实例未能正常启动/健康检查未通过，准备回滚到恢复前数据。"
      docker stop --time 20 "$container" >/dev/null 2>&1 || true
      if rollback_from_snapshot && docker start "$container" >/dev/null && vw_wait_healthy "$container" 30 2; then
        stopped_by_script=0
        data_change_started=0
        warn "已自动回滚到恢复前数据并成功启动。原回滚文件仍保留：$rollback_archive"
      else
        stopped_by_script=1
        data_change_started=1
        err "严重错误：恢复后的实例未通过健康检查，自动回滚/启动也未完全成功。容器可能保持停止。回滚文件：$rollback_archive"
        echo "请勿在 1Panel 中启动容器，先检查数据目录和回滚文件。"
      fi
      rm -rf -- "$staging" "$temp_root"
      return 1
    fi
  else
    stopped_by_script=0
    warn "已按你的选择保持容器停止。稍后可在 1Panel → 已安装应用中手动启动。"
  fi
  warn "请登录网页测试原用户、附件、TOTP 与同步。确认一切正常之前，不要删除原数据加密回滚快照：$rollback_archive"
  vw_perf_stage_end success
  ok "恢复暂存目录将在退出菜单时自动清理。"
  pause
)

verify_github_backup() (
  local temp_root="" repo_tmp="" restore_ssh_key="" identity="" identity_pub="" choice="" archive="" staging="" sqlite_result=""
  cleanup_verify() {
    [[ -n "${temp_root:-}" ]] && rm -rf -- "$temp_root"
    [[ -n "${staging:-}" ]] && rm -rf -- "$staging"
    return 0
  }
  trap cleanup_verify EXIT
  require_root
  load_config || return 1
  [[ -x "$RESTORE_SCRIPT" ]] || { err "恢复准备脚本尚未安装，请先运行菜单 1 或菜单 7 更新脚本。"; return 1; }
  if ! command -v sqlite3 >/dev/null 2>&1; then
    warn "当前未安装 sqlite3；可选的数据库 quick_check 将跳过，但仍会检查 SHA256、age 解密和 tar 内容。"
  fi
  temp_root=$(mktemp -d /var/tmp/vw-verify.XXXXXX)
  chmod 700 "$temp_root"
  repo_tmp="$temp_root/repository"
  restore_ssh_key=$(read_default "GitHub SSH 私钥路径" "$GITHUB_SSH_KEY")
  [[ -f "$restore_ssh_key" ]] || { err "找不到 GitHub SSH 私钥：$restore_ssh_key"; return 1; }
  echo "正在从 GitHub 读取备份列表..."
  clone_for_restore "$GITHUB_REPO" "$GITHUB_BRANCH" "$repo_tmp" "$restore_ssh_key" || { err "无法克隆备份仓库。"; return 1; }
  local -a archives=()
  mapfile -t archives < <(find "$repo_tmp" -maxdepth 1 -type f -name 'vw-*.tar.gz.age' -printf '%f\n' | sort -r)
  ((${#archives[@]} > 0)) || { err "GitHub 仓库中没有发现 vw-*.tar.gz.age。"; return 1; }
  echo "可验证备份（按时间从新到旧）："
  local i
  for i in "${!archives[@]}"; do
    printf '  %d) %s (%s)\n' "$((i+1))" "${archives[$i]}" "$(stat -c '%s bytes' "$repo_tmp/${archives[$i]}")"
  done
  read -r -p "请输入要验证的备份编号: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#archives[@]})) || { err "编号无效。"; return 1; }
  archive="$repo_tmp/${archives[$((choice-1))]}"
  [[ -s "$archive" && -s "$archive.sha256" ]] || { err "备份文件或 SHA256 文件不存在/为空。"; return 1; }
  echo
  echo "第 1 项：SHA256 校验"
  (cd "$repo_tmp" && sha256sum -c "$(basename "$archive").sha256") || { err "SHA256 校验失败。"; return 1; }
  echo
  echo "第 2 项：验证 age 私钥"
  identity=$(read_default "原 age 私钥文件路径（必须与此备份匹配）" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}")
  [[ -f "$identity" ]] || { err "找不到 age 私钥：$identity"; return 1; }
  identity_pub=$(age-keygen -y "$identity") || { err "无法读取 age 私钥。"; return 1; }
  [[ "$identity_pub" == "$AGE_RECIPIENT" ]] || { err "该私钥对应的公钥与当前配置不匹配。"; return 1; }
  echo
  echo "第 3 项：实际解密、读取归档目录"
  staging="$temp_root/staging"
  bash "$RESTORE_SCRIPT" "$archive" "$identity" "$staging" || { err "解密或归档检查失败。"; return 1; }
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
  echo "这只是离线数据可读性测试，不会停止或修改当前 Vaultwarden。"
  echo "验证文件：$(basename "$archive")"
  pause
)


restore_rehearsal() (
  set -Eeuo pipefail
  local temp_root="" repo_tmp="" identity="" restore_ssh_key="" archive="" staging="" container="" image="" test_name="" choice="" state="" health="" i
  local -a archives=()
  cleanup_rehearsal() {
    if [[ -n "${test_name:-}" ]] && docker inspect "$test_name" >/dev/null 2>&1; then
      docker rm -f "$test_name" >/dev/null 2>&1 || true
    fi
    [[ -n "${temp_root:-}" ]] && rm -rf -- "$temp_root"
    return 0
  }
  trap cleanup_rehearsal EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  require_root
  require_docker || return 1
  load_config || return 1
  [[ -x "$RESTORE_SCRIPT" ]] || { err "恢复准备脚本未安装，请先运行菜单 7。"; return 1; }
  local -a container_candidates=()
  if ! vw_find_target "$CONTAINER" "$DATA_DIR" true; then
    err "无法确认生产 Vaultwarden 容器和 /data 路径。恢复演练停止。"
    return 1
  fi
  image="$VW_DETECTED_IMAGE"
  container="$VW_DETECTED_CONTAINER"
  docker image inspect "$image" >/dev/null 2>&1 || { err "当前镜像在本机不存在：$image。请先在 1Panel 正常更新/拉取后再演练。"; return 1; }
  temp_root=$(mktemp -d /var/tmp/vw-drill.XXXXXX); chmod 700 "$temp_root"
  repo_tmp="$temp_root/repository"
  restore_ssh_key=$(read_default "GitHub SSH 私钥路径" "$GITHUB_SSH_KEY")
  [[ -f "$restore_ssh_key" ]] || { err "找不到 GitHub SSH 私钥：$restore_ssh_key"; return 1; }
  echo "正在读取 GitHub 历史备份..."
  clone_for_restore "$GITHUB_REPO" "$GITHUB_BRANCH" "$repo_tmp" "$restore_ssh_key" || { err "无法克隆备份仓库。"; return 1; }
  mapfile -t archives < <(find "$repo_tmp" -maxdepth 1 -type f -name 'vw-*.tar.gz.age' -printf '%f\n' | sort -r)
  ((${#archives[@]} > 0)) || { err "仓库中没有找到加密数据备份。"; return 1; }
  echo "可进行隔离容器启动测试的备份："
  for i in "${!archives[@]}"; do printf '  %2d) %s (%s)\n' "$((i+1))" "${archives[$i]}" "$(stat -c '%s bytes' "$repo_tmp/${archives[$i]}")"; done
  read -r -p "选择备份编号: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#archives[@]})) || { err "编号无效。"; return 1; }
  archive="$repo_tmp/${archives[$((choice-1))]}"
  identity=$(read_default "原 age 私钥文件路径" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}")
  [[ -f "$identity" ]] || { err "找不到原 age 私钥。"; return 1; }
  local pub
  pub=$(age-keygen -y "$identity") || { err "无法读取 age 私钥。"; return 1; }
  [[ "$pub" == "$AGE_RECIPIENT" ]] || { err "此私钥与配置中的 AGE_RECIPIENT 不匹配。"; return 1; }
  staging="$temp_root/staging"
  bash "$RESTORE_SCRIPT" "$archive" "$identity" "$staging" || { err "备份解密或 SQLite 检查失败。"; return 1; }
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
  for ((i=1; i<=30; i++)); do
    state=$(docker inspect -f '{{.State.Status}}' "$test_name" 2>/dev/null || echo missing)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$test_name" 2>/dev/null || echo unknown)
    if [[ "$state" == running && ( "$health" == healthy || "$health" == no-healthcheck ) ]]; then passed=1; break; fi
    [[ "$state" == exited || "$state" == dead || "$state" == missing ]] && break
    sleep 2
  done
  echo
  echo "临时容器状态：$state；健康检查：$health"
  echo "临时容器启动日志："
  docker logs --tail 60 "$test_name" 2>&1 || true
  if ((passed==1)); then
    ok "隔离恢复演练通过：归档成功解密，SQLite 检查已通过，Vaultwarden 容器进程正常运行。"
    echo "本次未暴露 HTTP 端口，也未连接生产网络。"
  else
    err "隔离恢复演练未通过。生产容器和生产数据未被修改；请检查上面的临时容器日志、镜像兼容性和该备份版本。"
  fi
  docker rm -f "$test_name" >/dev/null 2>&1 || true
  test_name=""
  return $((passed==1 ? 0 : 1))
)

install_systemd_timer() {
  load_config || return 1
  command -v systemctl >/dev/null 2>&1 || { err "当前系统没有 systemctl，无法使用 systemd timer。"; return 1; }
  local hhmm frequency calendar default_hhmm
  echo "可选备份频率：daily（每天）、weekly（每周日）、monthly（每月 1 日）。"
  frequency=$(read_default "备份频率 daily/weekly/monthly" "${BACKUP_FREQUENCY:-daily}")
  frequency="${frequency,,}"
  [[ "$frequency" == daily || "$frequency" == weekly || "$frequency" == monthly ]] || { err "频率仅支持 daily、weekly 或 monthly。"; return 1; }
  default_hhmm=$(grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}$' <<< "${SYSTEMD_TIME:-*-*-* 05:20:00}" | sed 's/:00$//')
  default_hhmm="${default_hhmm:-05:20}"
  hhmm=$(read_default "备份执行时间（VPS 本地时间，HH:MM）" "$default_hhmm")
  [[ "$hhmm" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { err "时间格式不正确，请使用 05:20 这样的 HH:MM 格式。"; return 1; }
  case "$frequency" in
    daily) calendar="*-*-* ${hhmm}:00" ;;
    weekly) calendar="Sun *-*-* ${hhmm}:00" ;;
    monthly) calendar="*-*-01 ${hhmm}:00" ;;
  esac
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "$calendar" >/dev/null 2>&1 || { err "systemd 不接受这个日历表达式：$calendar"; return 1; }
  fi
  SYSTEMD_TIME="$calendar"
  BACKUP_FREQUENCY="$frequency"
  vw_save_config || { err "保存配置失败。"; return 1; }
  cat > /etc/systemd/system/vw-backup.service <<'UNIT'
[Unit]
Description=Scheduled Vaultwarden encrypted backup to GitHub
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
Environment=VW_EXECUTION_MODE=systemd
ExecStart=/usr/local/sbin/vw-backup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=infinity
UNIT
  cat > /etc/systemd/system/vw-backup.timer <<UNIT
[Unit]
Description=Scheduled Vaultwarden backup timer

[Timer]
OnCalendar=${SYSTEMD_TIME}
Persistent=true
AccuracySec=1s
Unit=vw-backup.service

[Install]
WantedBy=timers.target
UNIT
  chmod 644 /etc/systemd/system/vw-backup.service /etc/systemd/system/vw-backup.timer
  systemctl daemon-reload || return 1
  systemctl enable --now vw-backup.timer || return 1
  case "$frequency" in
    daily) ok "systemd 自动备份已启用：每天 VPS 本地时间 $hhmm。" ;;
    weekly) ok "systemd 自动备份已启用：每周日 VPS 本地时间 $hhmm。" ;;
    monthly) ok "systemd 自动备份已启用：每月 1 日 VPS 本地时间 $hhmm。" ;;
  esac
  warn "如果以前配置过 1Panel 计划任务，请将旧任务停用，避免同一时间重复备份。"
  systemctl list-timers --all | grep -E 'NEXT|vw-backup' || true
  pause
}

systemd_timer_status() {
  echo "========== systemd 定时备份状态 =========="
  if systemctl list-unit-files vw-backup.timer --no-legend 2>/dev/null | grep -q vw-backup.timer; then
    systemctl status --no-pager vw-backup.timer 2>&1 || true
    echo
    systemctl list-timers --all --no-pager | grep -E 'NEXT|vw-backup' || true
    echo
    systemctl show vw-backup.service -p Result -p ExecMainStatus -p ExecMainStartTimestamp -p ExecMainExitTimestamp 2>/dev/null || true
  else
    warn "尚未安装 systemd timer。"
  fi
  pause
}

pause_systemd_timer() {
  if ! systemctl list-unit-files vw-backup.timer --no-legend 2>/dev/null | grep -q vw-backup.timer; then warn "systemd timer 尚未安装。"; pause; return 0; fi
  confirm_yes_upper "确认暂停并禁用自动备份？现有备份不会删除。" || return 0
  systemctl disable --now vw-backup.timer
  ok "自动备份已暂停。后台脚本和历史数据均保留。"
  pause
}

resume_systemd_timer() {
  if [[ ! -f /etc/systemd/system/vw-backup.timer ]]; then err "找不到 timer 文件，请先使用菜单 9 安装/配置。"; return 1; fi
  systemctl daemon-reload
  systemctl enable --now vw-backup.timer
  ok "自动备份已恢复。"
  systemctl list-timers --all | grep -E 'NEXT|vw-backup' || true
  pause
}

configure_notifications() {
  load_config || return 1
  echo "通知支持：none（关闭）、telegram、ntfy、webhook。通知失败不会影响备份结果。"
  local method
  method=$(read_default "通知方式" "${NOTIFY_METHOD:-none}")
  method="${method,,}"
  case "$method" in
    none|telegram|ntfy|webhook) ;;
    *) err "不支持的通知方式。"; return 1 ;;
  esac
  NOTIFY_METHOD="$method"
  case "$method" in
    telegram)
      read -r -p "Telegram Bot Token（输入内容不会回显）: " -s TELEGRAM_BOT_TOKEN; echo
      read -r -p "Telegram Chat ID: " TELEGRAM_CHAT_ID
      ;;
    ntfy)
      NTFY_URL=$(read_default "ntfy 完整 Topic URL（例如 https://ntfy.sh/your-private-topic）" "${NTFY_URL:-}")
      read -r -p "ntfy Access Token（没有则直接回车）: " -s NTFY_TOKEN; echo
      ;;
    webhook)
      read -r -p "Webhook URL（输入内容不会回显）: " -s WEBHOOK_URL; echo
      ;;
    none)
      TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""; NTFY_URL=""; NTFY_TOKEN=""; WEBHOOK_URL=""
      ;;
  esac
  NOTIFY_ON_SUCCESS=$(read_default "是否发送备份成功通知 true/false" "${NOTIFY_ON_SUCCESS:-true}")
  NOTIFY_ON_FAILURE=$(read_default "是否发送备份失败通知 true/false" "${NOTIFY_ON_FAILURE:-true}")
  vw_save_config || { err "保存通知配置失败。"; return 1; }
  ok "通知配置已保存到权限为 600 的配置文件。"
  if [[ "$NOTIFY_METHOD" != none ]]; then
    vw_notify success "Vaultwarden Backup Manager notification test from $(hostname)."
    info "已发送测试通知；请检查你的 Telegram、ntfy 或 Webhook 接收端。"
  fi
  pause
}

preupgrade_backup() {
  load_config || return 1
  echo "升级前保护：先运行一次完整备份。只有备份脚本返回成功且远端提交校验通过，才建议继续在 1Panel 更新 Vaultwarden。"
  confirm_yes_upper "确认现在创建升级前备份？" || return 0
  if bash "$BACKUP_SCRIPT"; then
    ok "升级前备份成功。现在可以进入 1Panel → 已安装应用 → Vaultwarden 执行更新。"
    warn "本工具不会自动升级 Vaultwarden；升级后可再次运行菜单 4 检查新容器名称，并观察下一次备份。"
  else
    err "升级前备份失败。请勿继续更新 Vaultwarden，先查看日志并修复问题。"
    return 1
  fi
  pause
}

configure_backup_policy() {
  load_config || return 1
  local retention max_mib min_free retries delay
  echo "========== 备份策略 =========="
  retention=$(read_default "本地及 Git 当前分支文件保留天数（Git 历史仍会保留旧对象）" "${RETENTION_DAYS:-30}")
  max_mib=$(read_default "单个加密备份文件最大 MiB（建议不超过 90）" "${MAX_FILE_MIB:-90}")
  min_free=$(read_default "数据盘最少可用空间 MB；不足则跳过备份" "${MIN_FREE_MB:-512}")
  retries=$(read_default "GitHub 推送失败重试次数（1-10）" "${GIT_PUSH_RETRIES:-3}")
  delay=$(read_default "每次重试基础等待秒数" "${GIT_RETRY_DELAY:-15}")
  [[ "$retention" =~ ^[0-9]+$ ]] && ((retention >= 1 && retention <= 3650)) || { err "保留天数必须为 1-3650。"; return 1; }
  [[ "$max_mib" =~ ^[0-9]+$ ]] && ((max_mib >= 1 && max_mib <= 95)) || { err "文件限制必须为 1-95 MiB。"; return 1; }
  [[ "$min_free" =~ ^[0-9]+$ ]] && ((min_free >= 100)) || { err "最少可用空间至少为 100 MB。"; return 1; }
  [[ "$retries" =~ ^[0-9]+$ ]] && ((retries >= 1 && retries <= 10)) || { err "重试次数必须为 1-10。"; return 1; }
  [[ "$delay" =~ ^[0-9]+$ ]] && ((delay >= 1 && delay <= 600)) || { err "等待秒数必须为 1-600。"; return 1; }
  RETENTION_DAYS="$retention"; MAX_FILE_MIB="$max_mib"; MIN_FREE_MB="$min_free"; GIT_PUSH_RETRIES="$retries"; GIT_RETRY_DELAY="$delay"
  vw_save_config || { err "保存配置失败。"; return 1; }
  ok "备份策略已保存。"
  pause
}

generate_diagnostics() {
  local diagnostic_script="" report_dir="${VW_DIAG_REPORT_DIR:-/var/log/vaultwarden-backup-diagnostics}" latest_report=""
  # Prefer the diagnostic script shipped with the source checkout. This lets
  # users test the current project copy even before installing/updating helpers.
  if [[ -f "$SCRIPT_DIR/vw-diagnose.sh" ]]; then
    diagnostic_script="$SCRIPT_DIR/vw-diagnose.sh"
  elif [[ -f /usr/local/sbin/vw-diagnose.sh ]]; then
    diagnostic_script="/usr/local/sbin/vw-diagnose.sh"
  else
    err "找不到诊断脚本。请从完整项目目录运行，或先选择菜单 7 更新后台脚本。"
    return 1
  fi

  echo "========== 系统诊断报告 =========="
  echo "诊断脚本：$diagnostic_script"
  echo "报告目录：$report_dir"
  echo "报告会省略配置中的密码、Token 和私钥内容。"
  if ! bash "$diagnostic_script"; then
    err "诊断脚本执行失败。请检查上方错误信息。"
    return 1
  fi
  latest_report=$(find "$report_dir" -maxdepth 1 -type f -name 'diagnosis-*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)
  if [[ -n "$latest_report" && -s "$latest_report" ]]; then
    chmod 600 "$latest_report" 2>/dev/null || true
    ok "诊断报告已生成：$latest_report"
    ls -lh -- "$latest_report"
  else
    err "脚本未生成诊断报告。请检查目录权限：$report_dir"
    return 1
  fi
  pause
}

manage_history() (
  set -Eeuo pipefail
  load_config || return 1
  local temp repo_tmp choice action file base manifest marker_content
  local -a files=()
  mkdir -p /run/lock
  exec 8>"/run/lock/vaultwarden-backup.lock"
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
  read -r -p "输入备份编号: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#files[@]})) || { err "编号无效。"; return 1; }
  file="${files[$((choice-1))]}"
  base="${file%.tar.gz.age}"
  manifest="${base}.manifest.json.age"
  case "$action" in
    1)
      if [[ -e "$repo_tmp/$file.keep" ]]; then warn "该备份已经标记为永久保留。"; pause; return 0; fi
      marker_content="Protected by Vaultwarden 1Panel Backup Manager on $(date '+%F %T %Z'). This marker keeps this backup in the current Git branch and local retention cleanup."
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
      if [[ -e "$repo_tmp/$file.keep" ]]; then err "该备份已标记为永久保留。请先选择操作 2 取消保护，再删除。"; return 1; fi
      echo "将从 GitHub 当前分支和本地备份目录删除：$file、校验文件，以及对应部署清单（如存在）。"
      echo "注意：Git 历史提交中的旧对象仍可能保留这些数据。"
      confirm_yes_upper "确认删除这个备份？此操作会移除当前分支可见文件。" || { warn "已取消。"; return 0; }
      rm -f -- "$repo_tmp/$file" "$repo_tmp/$file.sha256" "$repo_tmp/$manifest" "$repo_tmp/$manifest.sha256"
      ;;
  esac
  git -C "$repo_tmp" add -A
  if git -C "$repo_tmp" diff --cached --quiet; then
    info "没有文件变化，无需提交。"; pause; return 0
  fi
  git -C "$repo_tmp" commit -m "Manage backup retention: ${file}"
  git -C "$repo_tmp" push origin "$GITHUB_BRANCH"
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
      rm -f -- "$BACKUP_DIR/$file" "$BACKUP_DIR/$file.sha256" "$BACKUP_DIR/$manifest" "$BACKUP_DIR/$manifest.sha256"
      ok "已从当前分支删除备份文件。Git 历史对象仍可能保留旧数据。" ;;
  esac
  pause
)

view_deployment_manifest() (
  set -Eeuo pipefail
  load_config || return 1
  local temp repo_tmp identity choice file
  local -a manifests=()
  temp=$(mktemp -d /var/tmp/vw-manifest.XXXXXX); chmod 700 "$temp"
  trap 'rm -rf -- "$temp"' EXIT
  repo_tmp="$temp/repo"
  make_ssh_command "$GITHUB_SSH_KEY"
  git clone --quiet --branch "$GITHUB_BRANCH" "$GITHUB_REPO" "$repo_tmp" || { err "无法读取备份仓库。"; return 1; }
  mapfile -t manifests < <(find "$repo_tmp" -maxdepth 1 -type f -name 'vw-*.manifest.json.age' -printf '%f\n' | sort -r)
  ((${#manifests[@]} > 0)) || { warn "没有找到部署清单。请先运行一次新版备份。"; return 0; }
  local i
  for i in "${!manifests[@]}"; do printf '  %d) %s\n' "$((i+1))" "${manifests[$i]}"; done
  read -r -p "选择清单编号: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#manifests[@]})) || { err "编号无效。"; return 1; }
  file="${manifests[$((choice-1))]}"
  identity=$(read_default "原 age 私钥文件路径" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}")
  [[ -f "$identity" ]] || { err "找不到 age 私钥。"; return 1; }
  (cd "$repo_tmp" && sha256sum -c "$file.sha256") || { err "部署清单 SHA256 校验失败。"; return 1; }
  age -d -i "$identity" "$repo_tmp/$file" > "$temp/manifest.json" || { err "部署清单解密失败。"; return 1; }
  echo "以下清单已经进行脱敏处理，秘密变量值不会显示："
  cat "$temp/manifest.json"
  echo
  warn "清单用于手动复现 1Panel 应用配置，不包含 SMTP 密码、Admin Token 或其他秘密值。"
  pause
)

performance_monitor() {
  local tool="$SCRIPT_DIR/vw-performance.py" choice perf_file="/var/lib/vaultwarden-backup/performance.tsv"
  [[ -f "$tool" ]] || tool="/usr/local/libexec/vw-performance.py"
  [[ -f "$tool" ]] || { err "找不到性能分析工具，请从项目目录运行菜单 07 更新脚本。"; pause; return 1; }
  if [[ ! -f "$perf_file" ]]; then
    warn "尚未找到性能记录文件：$perf_file"
    echo "v1.4.2 手动备份会直接调用当前项目中的计时版 worker。"
    echo "systemd 自动备份使用系统安装版 worker；更新项目后请先执行菜单 07 同步后台脚本。"
    echo "完成一次成功或失败的手动备份/恢复后，再返回此处查看性能记录。"
    pause
    return 0
  fi
  while true; do
    clear 2>/dev/null || true
    echo "╭──────────────────────────────────────────────────────────────╮"
    echo "│             性能监控与执行耗时分析                           │"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│ [1] 查看总体摘要与最近 20 次操作                              │"
    echo "│ [2] 查看最近阶段耗时明细                     │"
    echo "│ [3] 查看指定运行 ID 的详细阶段耗时                            │"
    echo "│ [4] 导出完整 CSV 性能记录                                     │"
    echo "│ [0] 返回主菜单                                                │"
    echo "╰──────────────────────────────────────────────────────────────╯"
    read -r -p "请选择 [0-4]: " choice || return 0
    case "$choice" in
      1) python3 "$tool" "$perf_file"; pause ;;
      2) python3 "$tool" "$perf_file" --recent; pause ;;
      3)
        read -r -p "输入运行 ID（可从最近运行列表复制）: " run_id
        [[ -n "$run_id" ]] && python3 "$tool" "$perf_file" --details "$run_id"
        pause
        ;;
      4)
        local out="/var/backups/vaultwarden/performance-$(date +%Y%m%d-%H%M%S).csv"
        mkdir -p "$(dirname "$out")"; chmod 700 "$(dirname "$out")"
        python3 "$tool" "$perf_file" --csv "$out"
        chmod 600 "$out" 2>/dev/null || true
        pause
        ;;
      0|00) return 0 ;;
      *) warn "无效选项。"; sleep 1 ;;
    esac
  done
}

show_logs() {
  if [[ -f "$LOG_FILE" ]]; then tail -n 100 "$LOG_FILE"; else warn "日志文件尚不存在：$LOG_FILE"; fi
  pause
}

show_schedule_help() {
  cat <<'TXT'
推荐使用 Ubuntu/Debian 原生 systemd timer，不依赖 1Panel 计划任务。
主菜单 9 安装/修改时间，10 查看状态，11 暂停，12 恢复。
默认每天 05:20，按 VPS 系统本地时区运行；Persistent=true 可在 VPS 关机错过计划后，于下次启动补执行。

若此前已经在 1Panel 创建同一时间的计划任务，请停用旧任务，避免重复备份。
手动执行后台备份：systemctl start vw-backup.service
查看运行日志：journalctl -u vw-backup.service -n 100
查看脚本日志：tail -n 100 /var/log/vaultwarden-backup.log
TXT
  pause
}

check_for_project_updates() {
  [[ "${VBM_SKIP_UPDATE_CHECK:-0}" == "1" ]] && return 0
  local project_root="${VBM_PROJECT_ROOT:-$(readlink -f -- "$SCRIPT_DIR/.." 2>/dev/null || printf '%s' "")}" branch local_head remote_head remote_version dirty answer
  [[ -n "$project_root" && -d "$project_root/.git" ]] || return 0
  git -C "$project_root" remote get-url origin >/dev/null 2>&1 || return 0
  branch=$(git -C "$project_root" branch --show-current 2>/dev/null || true)
  [[ -n "$branch" ]] || return 0
  printf '\n正在检查 GitHub 是否有新版...\n'
  if ! timeout 15s git -C "$project_root" fetch --quiet --no-tags origin "$branch"; then
    warn "暂时无法检查 GitHub 更新（网络不可用或访问超时）；继续使用本地版本 v${VERSION}。"
    return 0
  fi
  remote_head=$(git -C "$project_root" rev-parse FETCH_HEAD 2>/dev/null || true)
  local_head=$(git -C "$project_root" rev-parse HEAD 2>/dev/null || true)
  [[ -n "$remote_head" && -n "$local_head" ]] || return 0
  if [[ "$remote_head" == "$local_head" ]]; then
    ok "当前已是最新版本 v${VERSION}。"
    return 0
  fi
  if ! git -C "$project_root" merge-base --is-ancestor "$local_head" "$remote_head" 2>/dev/null; then
    warn "远程仓库与本地提交不是简单的快进关系，自动更新已跳过。请先手动检查 Git 状态。"
    return 0
  fi
  remote_version=$(git -C "$project_root" show "$remote_head:scripts/vw-manager.sh" 2>/dev/null | sed -n 's/^VERSION="\([^"]*\)"$/\1/p' | head -n 1)
  remote_version="${remote_version:-未知}"
  dirty=$(git -C "$project_root" status --porcelain 2>/dev/null || true)
  echo
  warn "发现 GitHub 新提交：${local_head:0:8} -> ${remote_head:0:8}（远程版本：v${remote_version}）"
  if [[ -n "$dirty" ]]; then
    warn "当前项目目录存在未提交修改，为保护本地文件，不自动更新。请先提交或备份本地修改后再更新。"
    return 0
  fi
  read -r -p "是否现在更新到 GitHub 最新版本？输入 yes 更新 [y/N]: " answer || true
  if [[ "${answer,,}" != "yes" && "${answer,,}" != "y" ]]; then
    info "已跳过更新，继续使用当前版本 v${VERSION}。"
    return 0
  fi
  if ! git -C "$project_root" pull --ff-only origin "$branch"; then
    err "自动更新失败。未执行强制覆盖，请检查网络和 Git 状态。"
    return 0
  fi
  ok "项目源码更新成功。正在同步更新系统后台脚本、性能工具和全局启动器..."
  if ! install_helper_scripts; then
    warn "源码已更新，但系统后台脚本安装未全部完成。进入菜单后请运行 [07] 重试更新后台脚本。"
  else
    ok "系统后台脚本已同步到最新版本。"
  fi
  exec env VBM_SKIP_UPDATE_CHECK=1 VBM_PROJECT_ROOT="$project_root" bash "$project_root/run.sh"
}

render_main_menu() {
  python3 - "$VERSION" <<'PYMENU'
import sys, unicodedata
version = sys.argv[1]
W = 82

def width(s):
    total = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        total += 2 if unicodedata.east_asian_width(ch) in ("F", "W") else 1
    return total

def pad(s, align="left"):
    n = W - width(s)
    if n < 0:
        s = s[:max(0, len(s)-1)]
        n = max(0, W-width(s))
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
row("Vaultwarden Manager", "center")
row(f"v{version} · 1Panel Edition · Ubuntu / Debian", "center")
row("Powered by OmenTwwnmfm", "center")
row()
row("1Panel 负责应用、Docker、HTTPS；本工具负责数据保护与恢复。")
row("自动备份使用 systemd timer，不依赖 1Panel 计划任务。")
sep()
sections = [
    ("01 · 环境管理", [
        "[01] 首次配置 / 重新检测容器与数据目录",
        "[02] 立即备份当前数据并推送 GitHub",
        "[03] 从 GitHub 选择备份并恢复数据",
        "[04] 检查当前环境和备份配置"]),
    ("02 · 备份管理", [
        "[05] 查看最近备份日志",
        "[06] 查看自动备份定时任务帮助",
        "[07] 更新已安装的后台脚本（保留现有配置）",
        "[08] 验证 GitHub 历史备份（SHA256 / age / SQLite）"]),
    ("03 · 自动化管理", [
        "[09] 安装 systemd 自动备份 / 修改执行时间",
        "[10] 查看 systemd 定时任务状态",
        "[11] 暂停自动备份",
        "[12] 恢复自动备份"]),
    ("04 · 安全与诊断", [
        "[13] 配置通知（Telegram / ntfy / Webhook）并发送测试",
        "[14] Vaultwarden 更新前自动备份保护",
        "[15] 生成系统诊断报告"]),
    ("05 · 历史与恢复", [
        "[16] 历史备份管理（查看 / 永久保留 / 取消保留 / 删除）",
        "[17] 查看加密部署清单",
        "[18] 隔离恢复演练（不连接生产网络、不修改生产数据）"]),
    ("06 · 策略设置", [
        "[19] 配置备份策略（保留天数 / 磁盘阈值 / 推送重试）"]),
    ("07 · 性能监控", [
        "[20] 性能监控与执行耗时分析（备份 / 恢复 / GitHub / 校验）"]),
    ("08 · 项目维护", [
        "[21] 检查 / 更新项目源码"]),
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
  require_tty
  if [[ "${VBM_SKIP_UPDATE_CHECK:-0}" == "1" ]]; then
    unset VBM_SKIP_UPDATE_CHECK
  else
    check_for_project_updates
  fi
  while true; do
    clear 2>/dev/null || true
    render_main_menu
    read -r -p "请选择操作 [00-21]: " choice || exit 0
    case "$choice" in
      1|01) configure_wizard || pause ;;
      2|02) run_backup_now || true ;;
      3|03) restore_from_github || pause ;;
      4|04) check_configuration || pause ;;
      5|05) show_logs ;;
      6|06) show_schedule_help ;;
      7|07) update_installed_scripts || pause ;;
      8|08) verify_github_backup || pause ;;
      9|09) install_systemd_timer || pause ;;
      10) systemd_timer_status ;;
      11) pause_systemd_timer || pause ;;
      12) resume_systemd_timer || pause ;;
      13) configure_notifications || pause ;;
      14) preupgrade_backup || pause ;;
      15) generate_diagnostics || pause ;;
      16) manage_history || pause ;;
      17) view_deployment_manifest || pause ;;
      18) restore_rehearsal || pause ;;
      19) configure_backup_policy || pause ;;
      20) performance_monitor ;;
      21) check_for_project_updates; pause ;;
      0|00) echo "已退出。"; exit 0 ;;
      *) warn "无效选项，请输入 00-21。"; sleep 1 ;;
    esac
  done
}

main_menu "$@"
