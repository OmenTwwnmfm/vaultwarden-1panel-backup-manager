#!/usr/bin/env bash
# shellcheck shell=bash
# Installation and scheduling: helper install/update, systemd timer, pre-upgrade backup and backup policy.
# Sourced by vw-manager.sh through vbm_source_trusted; relies on its globals and helpers.

install_helper_scripts() {
  local source_dir="$SCRIPT_DIR" module
  [[ -f "$source_dir/vw-maintenance.sh" ]] || { err "缺少 vw-maintenance.sh。"; return 1; }
  [[ -f "$source_dir/vw-storage.py" ]] || { err "缺少 vw-storage.py。"; return 1; }
  for module in "${MANAGER_MODULES[@]}"; do
    [[ -f "$source_dir/$module" ]] || { err "缺少管理器模块 $module。"; return 1; }
  done
  [[ -f "$source_dir/vw-manager.sh" && -f "$source_dir/vw-common.sh" && -f "$source_dir/vw-backup.sh" && -f "$source_dir/vw-restore-prepare.sh" && -f "$source_dir/vw-archive-check.py" && -f "$source_dir/vw-manifest.py" && -f "$source_dir/vw-diagnose.sh" && -f "$source_dir/vw-performance.py" && -f "$source_dir/vbm-launcher.sh" ]] || {
    err "项目脚本不完整，缺少公共库、备份/恢复或归档检查工具。"
    return 1
  }
  install -d -o root -g root -m 755 /usr/local/libexec /usr/local/sbin
  install -o root -g root -m 644 "$source_dir/vw-common.sh" /usr/local/libexec/vw-common.sh || return 1
  install -o root -g root -m 644 "$source_dir/vw-maintenance.sh" /usr/local/libexec/vw-maintenance.sh || return 1
  for module in "${MANAGER_MODULES[@]}"; do
    install -o root -g root -m 644 "$source_dir/$module" "/usr/local/libexec/$module" || return 1
  done
  install -o root -g root -m 700 "$source_dir/vw-backup.sh" "$BACKUP_SCRIPT" || return 1
  install -o root -g root -m 700 "$source_dir/vw-restore-prepare.sh" "$RESTORE_SCRIPT" || return 1
  install -o root -g root -m 755 "$source_dir/vw-archive-check.py" /usr/local/libexec/vw-archive-check.py || return 1
  install -o root -g root -m 755 "$source_dir/vw-manifest.py" /usr/local/libexec/vw-manifest.py || return 1
  install -o root -g root -m 700 "$source_dir/vw-diagnose.sh" /usr/local/sbin/vw-diagnose.sh || return 1
  install -o root -g root -m 755 "$source_dir/vw-performance.py" /usr/local/libexec/vw-performance.py || return 1
  install -o root -g root -m 755 "$source_dir/vw-storage.py" /usr/local/libexec/vw-storage.py || return 1
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
  for module in "${MANAGER_MODULES[@]}"; do echo "  /usr/local/libexec/$module"; done
  echo "  /usr/local/libexec/vw-manifest.py"
  echo "  /usr/local/libexec/vw-archive-check.py"
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
  echo "将更新管理器、备份/恢复/诊断/性能/WebDAV 工具、全局 vbm 命令及公共库，不会修改现有备份配置、age 公钥、SSH 密钥、WebDAV 凭据或远端备份。若 systemd timer 已安装，timer 文件会保留。"
  confirm_yes_upper "确认安装当前项目目录中的新版脚本？" || { warn "已取消。"; return 0; }
  install_helper_scripts || { err "脚本更新失败。"; return 1; }
  ok "更新完成。全局命令 vbm 已安装/更新；下一次备份将自动重新检测当前容器名称及 /data 主机目录。"
  pause
}

install_systemd_timer() {
  load_config || return 1
  command -v systemctl >/dev/null 2>&1 || { err "当前系统没有 systemctl，无法使用 systemd timer。"; return 1; }
  local hhmm frequency calendar default_hhmm target
  echo "可选备份频率：daily（每天）、weekly（每周日）、monthly（每月 1 日）。"
  target=$(read_default "定时备份目标（github / webdav）" "${BACKUP_TARGET:-github}")
  [[ "$target" == github || "$target" == webdav ]] || { err "备份目标仅支持 github 或 webdav。"; return 1; }
  if [[ "$target" == webdav ]]; then
    python3 "$STORAGE_TOOL" list >/dev/null || return 1
  elif [[ -z "$GITHUB_REPO" || ! -f "$GITHUB_SSH_KEY" || -z "${REPO_DIR:-}" || ! -d "$REPO_DIR/.git" ]]; then
    err "GitHub 仓库、SSH 私钥或本地工作目录未配置，请先运行菜单 [01]。"
    return 1
  fi
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
  BACKUP_TARGET="$target"
  PRIMARY_TARGET="$target"
  vw_update_config_values "SYSTEMD_TIME=$SYSTEMD_TIME" "BACKUP_FREQUENCY=$BACKUP_FREQUENCY" "BACKUP_TARGET=$BACKUP_TARGET" "PRIMARY_TARGET=$PRIMARY_TARGET" || { err "保存配置失败。"; return 1; }
  cat > /etc/systemd/system/vw-backup.service <<'UNIT'
[Unit]
Description=Scheduled Vaultwarden encrypted backup
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
  warn "如果以前配置过 1Panel 计划任务或 cron，请将旧任务停用，避免同一时间重复备份。"
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
  show_schedule_help
}

pause_systemd_timer() {
  if ! systemctl list-unit-files vw-backup.timer --no-legend 2>/dev/null | grep -q vw-backup.timer; then warn "systemd timer 尚未安装。"; pause; return 0; fi
  confirm_yes_upper "确认暂停并禁用自动备份？现有备份不会删除。" || return 0
  systemctl disable --now vw-backup.timer || return 1
  ok "自动备份已暂停。后台脚本和历史数据均保留。"
  pause
}

resume_systemd_timer() {
  if [[ ! -f /etc/systemd/system/vw-backup.timer ]]; then err "找不到 timer 文件，请先使用菜单 [14] 安装/配置。"; return 1; fi
  systemctl daemon-reload || return 1
  systemctl enable --now vw-backup.timer || return 1
  ok "自动备份已恢复。"
  systemctl list-timers --all | grep -E 'NEXT|vw-backup' || true
  pause
}

preupgrade_backup() {
  load_config || return 1
  echo "升级前保护将创建完整备份并上传至 $BACKUP_TARGET，本次备份通过远端核验后可继续更新 Vaultwarden。"
  confirm_yes_upper "确认现在创建升级前备份？" || return 0
  local worker="$BACKUP_SCRIPT" common_lib="$COMMON_LIB" manifest_tool="/usr/local/libexec/vw-manifest.py" run_id result_file rc=0
  [[ -f "$SCRIPT_DIR/vw-backup.sh" ]] && worker="$SCRIPT_DIR/vw-backup.sh"
  [[ -f "$SCRIPT_DIR/vw-common.sh" ]] && common_lib="$SCRIPT_DIR/vw-common.sh"
  [[ -f "$SCRIPT_DIR/vw-manifest.py" ]] && manifest_tool="$SCRIPT_DIR/vw-manifest.py"
  run_id="$(date '+%Y%m%d-%H%M%S')-$$"
  result_file="/var/lib/vaultwarden-backup/runs/$run_id.env"
  echo "本次备份运行 ID：$run_id"
  if VW_RUN_ID="$run_id" VW_COMMON_LIB="$common_lib" VW_MANIFEST_TOOL="$manifest_tool" bash "$worker" "$BACKUP_TARGET"; then rc=0; else rc=$?; fi
  if (( rc == 0 )) && [[ -f "$result_file" ]] \
    && grep -Fxq 'STATUS=success' "$result_file" \
    && grep -Fxq "RUN_ID=$run_id" "$result_file" \
    && grep -Fxq 'LOCAL_VERIFIED=true' "$result_file" \
    && grep -Fxq 'SERVICE_RESTORED=true' "$result_file" \
    && grep -Fxq "BACKUP_TARGET=$BACKUP_TARGET" "$result_file" \
    && grep -Fxq 'REMOTE_VERIFIED=true' "$result_file"; then
    ok "升级前备份成功。现在可以更新 Vaultwarden（1Panel → 已安装应用，或 docker compose pull && docker compose up -d）。"
    warn "升级后可运行菜单 [03] 检查容器，再观察下一次备份。"
  else
    if [[ -f "$result_file" ]] && grep -Fxq 'STATUS=skipped' "$result_file"; then
      err "本次升级前备份因另一个操作占用锁而跳过；不会允许继续升级。"
    else
      err "本次升级前备份未能完成本地校验、服务恢复和 $BACKUP_TARGET 远端核验。请勿继续更新 Vaultwarden。"
    fi
    return 1
  fi
  pause
}

configure_backup_policy() {
  load_config || return 1
  local retention max_mib min_free retries delay secondary snapshot remote_retention remote_keep
  echo "========== 备份策略 =========="
  retention=$(read_default "本地备份保留天数（清理前核验远端副本）" "${RETENTION_DAYS:-30}")
  max_mib=$(read_default "单个加密备份文件最大 MiB（建议不超过 90）" "${MAX_FILE_MIB:-90}")
  min_free=$(read_default "数据盘最少可用空间 MB；不足则跳过备份" "${MIN_FREE_MB:-512}")
  retries=$(read_default "GitHub 推送失败重试次数（1-10，WebDAV 不使用）" "${GIT_PUSH_RETRIES:-3}")
  delay=$(read_default "每次重试基础等待秒数" "${GIT_RETRY_DELAY:-15}")
  secondary=$(read_default "次目标 github / webdav / none" "${SECONDARY_TARGET:-none}")
  snapshot=$(read_default "快照模式 stop / online" "${SNAPSHOT_MODE:-stop}")
  if [[ "$snapshot" == online ]]; then
    warn "online 模式不停机：数据库用 SQLite .backup 保证一致，附件、Send 等文件在服务运行中打包，只是尽力而为；运行中文件变化时会重试一次后失败。生产环境推荐 stop。"
  fi
  remote_retention=$(read_default "WebDAV 远端保留天数（0 关闭）" "${WEBDAV_RETENTION_DAYS:-0}")
  remote_keep=$(read_default "WebDAV 至少保留最近几组" "${WEBDAV_MIN_KEEP:-7}")
  [[ "$retention" =~ ^[0-9]+$ ]] && ((retention >= 1 && retention <= 3650)) || { err "保留天数必须为 1-3650。"; return 1; }
  [[ "$max_mib" =~ ^[0-9]+$ ]] && ((max_mib >= 1 && max_mib <= 95)) || { err "文件限制必须为 1-95 MiB。"; return 1; }
  [[ "$min_free" =~ ^[0-9]+$ ]] && ((min_free >= 100)) || { err "最少可用空间至少为 100 MB。"; return 1; }
  [[ "$retries" =~ ^[0-9]+$ ]] && ((retries >= 1 && retries <= 10)) || { err "重试次数必须为 1-10。"; return 1; }
  [[ "$delay" =~ ^[0-9]+$ ]] && ((delay >= 1 && delay <= 600)) || { err "等待秒数必须为 1-600。"; return 1; }
  [[ "$secondary" == none || "$secondary" == github || "$secondary" == webdav ]] || { err "次目标无效。"; return 1; }
  [[ "$secondary" != "$BACKUP_TARGET" ]] || { err "主次目标必须不同。"; return 1; }
  [[ "$snapshot" == stop || "$snapshot" == online ]] || { err "快照模式无效。"; return 1; }
  [[ "$remote_retention" =~ ^(0|[1-9][0-9]{0,3})$ && "$remote_keep" =~ ^[1-9][0-9]{0,3}$ ]] || { err "WebDAV 保留参数无效。"; return 1; }
  RETENTION_DAYS="$retention"; MAX_FILE_MIB="$max_mib"; MIN_FREE_MB="$min_free"; GIT_PUSH_RETRIES="$retries"; GIT_RETRY_DELAY="$delay"
  SECONDARY_TARGET="$secondary"
  SNAPSHOT_MODE="$snapshot"
  WEBDAV_RETENTION_DAYS="$remote_retention"
  WEBDAV_MIN_KEEP="$remote_keep"
  vw_update_config_values "RETENTION_DAYS=$RETENTION_DAYS" "MAX_FILE_MIB=$MAX_FILE_MIB" "MIN_FREE_MB=$MIN_FREE_MB" \
    "GIT_PUSH_RETRIES=$GIT_PUSH_RETRIES" "GIT_RETRY_DELAY=$GIT_RETRY_DELAY" "SECONDARY_TARGET=$SECONDARY_TARGET" \
    "SNAPSHOT_MODE=$SNAPSHOT_MODE" "WEBDAV_RETENTION_DAYS=$WEBDAV_RETENTION_DAYS" "WEBDAV_MIN_KEEP=$WEBDAV_MIN_KEEP" || { err "保存配置失败。"; return 1; }
  ok "备份策略已保存。"
  pause
}

show_schedule_help() {
  cat <<'TXT'
推荐使用 Ubuntu/Debian 原生 systemd timer，不依赖 1Panel 计划任务或 cron。
主菜单 [14] 安装/修改自动备份，[15] 查看状态，[16] 暂停，[17] 恢复。
默认每天 05:20，按 VPS 系统本地时区运行；Persistent=true 可在 VPS 关机错过计划后，于下次启动补执行。

若此前已经在 1Panel 或 cron 创建同一时间的计划任务，请停用旧任务，避免重复备份。
手动执行后台备份：systemctl start vw-backup.service
查看运行日志：journalctl -u vw-backup.service -n 100
查看脚本日志：tail -n 100 /var/log/vaultwarden-backup.log
TXT
  pause
}
