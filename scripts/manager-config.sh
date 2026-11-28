#!/usr/bin/env bash
# shellcheck shell=bash
# Configuration: dependencies, container detection, config load/write, setup wizard, backup signing and configuration checks.
# Sourced by vw-manager.sh through vbm_source_trusted; relies on its globals and helpers.

install_dependencies() {
  local target="${1:-github}" missing=()
  local -a required=(age age-keygen sha256sum tar gzip flock sqlite3 python3 logrotate timeout ssh-keygen)
  if [[ "$target" == github ]]; then required+=(git ssh-keyscan); fi
  for cmd in "${required[@]}"; do
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
  local -a packages=(age coreutils tar gzip util-linux findutils sqlite3 python3 logrotate openssh-client)
  if [[ "$target" == github ]]; then packages+=(git); fi
  warn "需要安装备份工具：${packages[*]}。不会安装或修改 Docker。"
  confirm_yes "是否使用 apt 安装缺少的备份工具？" || { warn "已取消。"; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update; then err "apt-get update 失败，请检查 VPS 软件源和网络。"; return 1; fi
  if ! apt-get install -y "${packages[@]}"; then err "依赖安装失败。"; return 1; fi
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
    if [[ -n "${CONTAINER_MATCH:-}" && "$lower" == *"${CONTAINER_MATCH,,}"* ]] ||
        [[ -z "${CONTAINER_MATCH:-}" && ( "$lower" == *vaultwarden* || "$lower" == *bitwarden* ) ]]; then
      matches+=("$line")
    fi
  done
  if ((${#matches[@]} == 0)); then
    err "没有发现名称或镜像中包含 vaultwarden 的容器。请先确认 Vaultwarden 已通过 Docker 部署（1Panel 应用商店、docker compose 或 docker run）。"
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
    vw_perf_user_wait_begin
    read -r -p "请输入要管理的容器编号: " choice
    vw_perf_user_wait_end
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
  vw_require_secure_config "$CONFIG_FILE" || return 1
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
  BACKUP_TARGET="${PRIMARY_TARGET:-${BACKUP_TARGET:-github}}"
  SECONDARY_TARGET="${SECONDARY_TARGET:-none}"
  SNAPSHOT_MODE="${SNAPSHOT_MODE:-stop}"
  WEBDAV_RETENTION_DAYS="${WEBDAV_RETENTION_DAYS:-0}"
  WEBDAV_MIN_KEEP="${WEBDAV_MIN_KEEP:-7}"
  ALERT_MAX_BACKUP_AGE_HOURS="${ALERT_MAX_BACKUP_AGE_HOURS:-}"
  ALERT_MAX_DRILL_AGE_DAYS="${ALERT_MAX_DRILL_AGE_DAYS:-90}"
  CONTAINER_MATCH="${CONTAINER_MATCH:-}"
  GITHUB_REPO="${GITHUB_REPO:-}"
  GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
  GITHUB_SSH_KEY="${GITHUB_SSH_KEY:-/root/.ssh/vw_github_backup}"
}

write_config() {
  local container="$1" data_dir="$2" age_recipient="$3" github_repo="$4" branch="$5" ssh_key="$6" backup_dir="$7" repo_dir="$8" retention="$9" max_mib="${10}" identity_default="${11}"
  local tmp
  tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
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
    printf 'BACKUP_TARGET=%q\n' "${BACKUP_TARGET:-github}"
    local setting
    for setting in PRIMARY_TARGET SECONDARY_TARGET SNAPSHOT_MODE WEBDAV_RETENTION_DAYS WEBDAV_MIN_KEEP ALERT_MAX_BACKUP_AGE_HOURS ALERT_MAX_DRILL_AGE_DAYS CONTAINER_MATCH; do
      printf '%s=%q\n' "$setting" "${!setting-}"
    done
  } > "$tmp"
  local lock rc=0
  lock=$(vw_config_lock_path) || { rm -f -- "$tmp"; return 1; }
  (
    flock -w 30 9 || { err "等待配置文件写锁超时：$lock"; exit 1; }
    target_tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || exit 1
    install -o root -g root -m 600 "$tmp" "$target_tmp" || { rm -f -- "$target_tmp"; exit 1; }
    vw_atomic_replace "$target_tmp" "$CONFIG_FILE" || { rm -f -- "$target_tmp"; exit 1; }
  ) 9>"$lock" || rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

configure_wizard() {
  require_docker || return 1
  if [[ -f "$CONFIG_FILE" ]]; then load_config || return 1; fi
  BACKUP_TARGET=$(read_default "自动备份目标（github / webdav）" "${BACKUP_TARGET:-github}")
  [[ "$BACKUP_TARGET" == github || "$BACKUP_TARGET" == webdav ]] || { err "请选择 github 或 webdav。"; return 1; }
  PRIMARY_TARGET="$BACKUP_TARGET"
  install_dependencies "$BACKUP_TARGET" || return 1
  echo
  echo "========== 第 1 步：检测 Vaultwarden 容器 =========="
  list_vaultwarden_containers || return 1
  inspect_data_mount "$DETECTED_CONTAINER" || return 1

  echo
  echo "========== 第 2 步：配置备份目标 =========="
  local github_repo="${GITHUB_REPO:-}" branch="${GITHUB_BRANCH:-main}" ssh_key="${GITHUB_SSH_KEY:-/root/.ssh/vw_github_backup}" age_recipient identity_default backup_dir repo_dir="${REPO_DIR:-}" retention max_mib
  if [[ "$BACKUP_TARGET" == github ]]; then
  read -r -p "GitHub 专用 Private 备份仓库 SSH 地址（git@github.com:用户名/vaultwarden-backup.git）: " github_repo
  [[ "$github_repo" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] || { err "仓库地址格式不正确。请使用 git@github.com:用户名/仓库名.git"; return 1; }
  branch=$(read_default "GitHub 分支名" "$branch")
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    err "Git 分支名不合法：$branch"
    return 1
  fi
  ssh_key=$(read_default "GitHub SSH 私钥路径" "$ssh_key")
  repo_dir=$(read_default "GitHub 本地仓库目录" "${repo_dir:-/opt/vw-github-repo}")
  setup_github_ssh "$ssh_key" || return 1
  else
    configure_webdav || return 1
  fi

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
  backup_dir=$(read_default "本地加密备份目录" "${BACKUP_DIR:-/var/backups/vaultwarden}")
  retention=$(read_default "本地备份文件保留天数（WebDAV 由服务端管理远端保留）" "${RETENTION_DAYS:-30}")
  max_mib=$(read_default "GitHub 单文件大小上限 MiB" "${MAX_FILE_MIB:-90}")
  [[ "$retention" =~ ^[0-9]+$ ]] && ((retention >= 1)) || { err "保留天数必须是正整数。"; return 1; }
  [[ "$max_mib" =~ ^[0-9]+$ ]] && ((max_mib >= 1 && max_mib <= 95)) || { err "文件限制必须为 1 到 95 MiB。"; return 1; }
  local data_canon backup_canon repo_canon
  data_canon=$(readlink -f -- "$DETECTED_DATA_DIR")
  backup_canon=$(readlink -m -- "$backup_dir")
  if [[ "$BACKUP_TARGET" == github ]]; then repo_canon=$(readlink -m -- "$repo_dir"); fi
  local -a candidate_dirs=("$backup_canon")
  if [[ "$BACKUP_TARGET" == github ]]; then candidate_dirs+=("$repo_canon"); fi
  for candidate_dir in "${candidate_dirs[@]}"; do
    case "$candidate_dir" in
      /|/var|/var/lib|/var/lib/docker|/opt|/root|/home|/etc|/usr)
        err "备份目录或 Git 工作目录过于宽泛：$candidate_dir。请选择专用子目录。"
        return 1
        ;;
    esac
  done
  if paths_overlap "$data_canon" "$backup_canon" || { [[ "$BACKUP_TARGET" == github ]] && paths_overlap "$data_canon" "$repo_canon"; }; then
    err "本地备份目录/Git 工作目录不能与 Vaultwarden 数据目录相同、互相嵌套或覆盖。请重新选择独立目录。"
    return 1
  fi
  if [[ "$BACKUP_TARGET" == github ]] && paths_overlap "$backup_canon" "$repo_canon"; then
    err "本地加密备份目录和 Git 工作目录必须相互独立。请重新选择目录。"
    return 1
  fi

  echo
  echo "========== 配置摘要 =========="
  printf '容器名称：%s\n镜像：%s\n容器状态：%s\n主机数据目录：%s\n备份目标：%s\nage 公钥：%s\n本地备份目录：%s\n保留天数：%s\n' \
    "$DETECTED_CONTAINER" "$DETECTED_IMAGE" "$DETECTED_STATUS" "$DETECTED_DATA_DIR" "$BACKUP_TARGET" "$age_recipient" "$backup_dir" "$retention"
  if [[ "$BACKUP_TARGET" == github ]]; then
    printf 'GitHub 仓库：%s\n分支：%s\nSSH 私钥：%s\nGit 工作目录：%s\n' "$github_repo" "$branch" "$ssh_key" "$repo_dir"
  fi
  confirm_yes_upper "请确认上述容器和数据目录都是正确的。脚本后续只会操作所显示的 Vaultwarden 容器与 /data 数据目录。" || { warn "已取消。"; return 1; }

  write_config "$DETECTED_CONTAINER" "$DETECTED_DATA_DIR" "$age_recipient" "$github_repo" "$branch" "$ssh_key" "$backup_dir" "$repo_dir" "$retention" "$max_mib" "$identity_default" || return 1
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  if [[ "$BACKUP_TARGET" == github ]]; then
    init_or_clone_backup_repo "$github_repo" "$branch" "$repo_dir" "$ssh_key" || return 1
  fi

  install_helper_scripts || { err "后台脚本安装失败。"; return 1; }
  configure_backup_signing "$ssh_key" || return 1
  ok "配置已保存至 $CONFIG_FILE（权限 600），后台脚本已安装。"
  echo
  if [[ -f "$identity_default" ]]; then
    warn "age 私钥目前仍保存在本机：$identity_default。备份和定时任务只需要 age 公钥。"
    echo "请确认离线副本至少两份且已验证可读；确认后建议从 VPS 删除这份私钥。"
    echo "将来恢复时，再把离线私钥临时复制到服务器，并在菜单 [08] 中填写路径。"
  fi
  warn "请先用 [02] 完成备份测试，再用 [14] 安装自动备份。当前定时目标为 $BACKUP_TARGET。"
  pause
}

configure_backup_signing() {
  local deploy_key="$1"
  if python3 "$STORAGE_TOOL" check-signing --deploy-key "$deploy_key" >/dev/null 2>&1; then
    ok "备份签名已配置。"
  elif [[ ! -e "$BACKUP_SIGNING_DIR" && ! -L "$BACKUP_SIGNING_DIR" ]] &&
      confirm_yes "是否初始化独立的备份签名密钥？"; then
    python3 "$STORAGE_TOOL" init-signing || return 1
    ok "签名密钥已生成。请离线保存 $BACKUP_SIGNING_DIR/allowed_signers。"
  else
    warn "备份签名尚未就绪。请检查 $BACKUP_SIGNING_DIR 中的密钥与权限。"
  fi
}

accept_backup_signature() {
  local file="$1" response signature_status=0
  ALLOW_UNSIGNED=0
  python3 "$STORAGE_TOOL" verify-signature "$file" || signature_status=$?
  case "$signature_status" in
    0) return 0 ;;
    3)
      warn "此备份没有签名。只有确认来源可信的旧备份才能继续。"
      response=$(read_default "输入 UNSIGNED 继续" "")
      [[ "$response" == UNSIGNED ]] || return 1
      ALLOW_UNSIGNED=1
      ;;
    *) return 1 ;;
  esac
}

show_backup_locations() {
  local identity="${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}"
  local age_state="本机未找到，可从离线介质提供" ssh_state="本机未找到" webdav_location
  local signing_key_state="本机未找到" signing_public_state="本机未找到" signers_state="本机未找到"
  local github_location="未配置" git_worktree="${REPO_DIR:-未配置}"
  if [[ -f "$identity" ]]; then age_state="存在"; fi
  if [[ -f "$GITHUB_SSH_KEY" ]]; then ssh_state="存在"; fi
  if [[ -f "$BACKUP_SIGNING_DIR/backup" && ! -L "$BACKUP_SIGNING_DIR/backup" ]]; then signing_key_state="存在"; fi
  if [[ -f "$BACKUP_SIGNING_DIR/backup.pub" && ! -L "$BACKUP_SIGNING_DIR/backup.pub" ]]; then signing_public_state="存在"; fi
  if [[ -f "$BACKUP_SIGNING_DIR/allowed_signers" && ! -L "$BACKUP_SIGNING_DIR/allowed_signers" ]]; then signers_state="存在"; fi
  if [[ "$GITHUB_REPO" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]]; then
    github_location="$GITHUB_REPO（分支：$GITHUB_BRANCH）"
    git_worktree="${REPO_DIR:-/opt/vw-github-repo}"
  elif [[ -n "$GITHUB_REPO" ]]; then
    github_location="已配置，请在配置文件中查看仓库地址"
  fi
  if [[ ! -e "$WEBDAV_CONFIG_FILE" && ! -L "$WEBDAV_CONFIG_FILE" ]]; then
    webdav_location="未配置，请使用菜单 [12]"
  elif ! webdav_location=$(python3 "$STORAGE_TOOL" --config "$WEBDAV_CONFIG_FILE" location 2>/dev/null); then
    webdav_location="无法读取，请检查菜单 [12] 的配置"
  fi

  echo "========== 备份与密钥路径 =========="
  printf '本地加密备份目录：%s\n' "$BACKUP_DIR"
  printf 'GitHub 备份仓库：%s\nGitHub 本地工作目录：%s\n' "$github_location" "$git_worktree"
  printf 'WebDAV 备份目录：%s\n' "$webdav_location"
  printf 'age 恢复私钥默认路径：%s（%s）\n' "$identity" "$age_state"
  printf 'age 加密公钥配置位置：%s 中的 AGE_RECIPIENT\n' "$CONFIG_FILE"
  printf '备份签名私钥路径：%s/backup（%s）\n' "$BACKUP_SIGNING_DIR" "$signing_key_state"
  printf '备份签名公钥路径：%s/backup.pub（%s）\n' "$BACKUP_SIGNING_DIR" "$signing_public_state"
  printf '可信备份签名者名单：%s/allowed_signers（%s）\n' "$BACKUP_SIGNING_DIR" "$signers_state"
  printf 'GitHub SSH 私钥路径：%s（%s）\n' "$GITHUB_SSH_KEY" "$ssh_state"
  printf '备份配置文件：%s\nWebDAV 凭据文件：%s\n\n' "$CONFIG_FILE" "$WEBDAV_CONFIG_FILE"
}

check_configuration() {
  load_config || return 1
  show_backup_locations
  configure_backup_signing "$GITHUB_SSH_KEY" || return 1
  require_docker || return 1
  echo "========== 配置检查 =========="
  printf '配置中记录的容器：%s\n配置中记录的数据目录：%s\n' "$CONTAINER" "$DATA_DIR"
  if ! vw_find_target "$CONTAINER" "$DATA_DIR" true; then
    err "无法自动确认唯一的运行中 Vaultwarden 容器。请运行菜单 1 重新选择。"
    return 1
  fi
  if [[ "$CONTAINER" != "$VW_DETECTED_CONTAINER" || "$(readlink -f "$DATA_DIR")" != "$VW_DETECTED_DATA_DIR" ]]; then
    warn "检测到容器可能已被重建（1Panel 更新或 docker compose up 等），正在更新记录。"
    CONTAINER="$VW_DETECTED_CONTAINER"
    DATA_DIR="$VW_DETECTED_DATA_DIR"
    # shellcheck disable=SC2153 # AGE_RECIPIENT 等变量由 load_config 从配置文件载入
    write_config "$CONTAINER" "$DATA_DIR" "$AGE_RECIPIENT" "$GITHUB_REPO" "$GITHUB_BRANCH" "$GITHUB_SSH_KEY" "$BACKUP_DIR" "${REPO_DIR:-}" "$RETENTION_DAYS" "$MAX_FILE_MIB" "${AGE_IDENTITY_DEFAULT:-/root/vw-age-identity.txt}" || return 1
  fi
  printf '当前容器：%s\n镜像：%s\n状态：%s\n/data 主机目录：%s\n' \
    "$VW_DETECTED_CONTAINER" "$VW_DETECTED_IMAGE" "$VW_DETECTED_STATUS" "$VW_DETECTED_DATA_DIR"
  [[ -s "$DATA_DIR/db.sqlite3" ]] || { err "db.sqlite3 不存在或大小为 0。"; return 1; }
  [[ "$AGE_RECIPIENT" == age1* ]] || { err "age 公钥格式错误。"; return 1; }
  if [[ "$BACKUP_TARGET" == github ]]; then
    [[ -f "$GITHUB_SSH_KEY" ]] || { err "SSH 私钥不存在：$GITHUB_SSH_KEY"; return 1; }
  fi
  case "${SECONDARY_TARGET:-none}" in
    none) ;;
    github)
      [[ -n "$GITHUB_REPO" && -f "$GITHUB_SSH_KEY" && -d "${REPO_DIR:-}/.git" ]] ||
        { err "次目标 GitHub 配置不完整：需要仓库、SSH 私钥和 Git 工作目录。"; return 1; }
      ;;
    webdav)
      [[ -f "$WEBDAV_CONFIG_FILE" ]] || { err "次目标 WebDAV 尚未配置，请先运行菜单 [12]。"; return 1; }
      ;;
    *) err "SECONDARY_TARGET 配置无效：$SECONDARY_TARGET"; return 1 ;;
  esac
  printf '数据库大小：%s\n' "$(du -h "$DATA_DIR/db.sqlite3" | awk '{print $1}')"
  printf '整个 /data 大小：%s\n' "$(du -sh "$DATA_DIR" | awk '{print $1}')"
  printf '数据目录剩余磁盘：%s\n' "$(df -h "$DATA_DIR" | awk 'NR==2 {print $4}')"
  ok "本地数据路径及容器检查通过。"
  if [[ "$BACKUP_TARGET" == github || "${SECONDARY_TARGET:-none}" == github ]]; then
    echo "========== GitHub 容量 =========="
    show_github_capacity
  fi
  if [[ "${SNAPSHOT_MODE:-stop}" == online ]]; then
    warn "当前为 online 快照模式：只保证数据库一致，附件/Send 为尽力而为；生产环境推荐 stop 模式（菜单 [21]）。"
  fi
  if [[ "$BACKUP_TARGET" == webdav ]]; then
    python3 "$STORAGE_TOOL" list > /dev/null || return 1
    ok "WebDAV 目录读取连接正常。"
    pause
    return 0
  fi
  make_ssh_command "$GITHUB_SSH_KEY"
  if git ls-remote "$GITHUB_REPO" HEAD >/dev/null; then ok "GitHub SSH 仓库读取连接正常。"; else err "GitHub 仓库连接失败，请检查 Deploy Key 与仓库地址。"; return 1; fi
  pause
}
