#!/usr/bin/env bash
# shellcheck shell=bash
# Operations: notifications, diagnostics, performance monitor and logs.
# Sourced by vw-manager.sh through vbm_source_trusted; relies on its globals and helpers.

configure_notifications() {
  load_config || return 1
  echo "通知支持：none（关闭）、telegram、ntfy、webhook。通知失败不会影响备份或恢复结果。"
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
      local token token_prompt="Telegram Bot Token（输入内容不会回显）"
      if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then token_prompt+="，直接回车保留当前配对"; fi
      if ! read -r -s -p "$token_prompt: " token; then echo; return 1; fi
      echo
      if [[ -n "$token" ]]; then
        TELEGRAM_CHAT_ID=$(printf '%s\n' "$token" | vw_telegram_chat_id) || return 1
        TELEGRAM_BOT_TOKEN="$token"
        ok "已识别 Telegram 私聊 Chat ID。"
      elif [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        err "首次配置 Telegram 必须输入 Bot Token。"
        return 1
      fi
      ;;
    ntfy)
      NTFY_URL=$(read_default "ntfy 完整 Topic URL（例如 https://ntfy.sh/your-private-topic）" "${NTFY_URL:-}")
      vw_notify_url_allowed "$NTFY_URL" || { err "ntfy 地址必须使用 https://（仅本机 localhost/127.0.0.1 允许 http://），避免 Token 和告警内容明文传输。"; return 1; }
      read -r -p "ntfy Access Token（没有则直接回车）: " -s NTFY_TOKEN; echo
      ;;
    webhook)
      read -r -p "Webhook URL（输入内容不会回显）: " -s WEBHOOK_URL; echo
      vw_notify_url_allowed "$WEBHOOK_URL" || { err "Webhook 地址必须使用 https://（仅本机 localhost/127.0.0.1 允许 http://）。"; return 1; }
      ;;
    none)
      TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""; NTFY_URL=""; NTFY_TOKEN=""; WEBHOOK_URL=""
      ;;
  esac
  NOTIFY_ON_SUCCESS=$(read_default "是否发送备份成功通知 true/false" "${NOTIFY_ON_SUCCESS:-true}")
  NOTIFY_ON_FAILURE=$(read_default "是否发送备份失败通知 true/false" "${NOTIFY_ON_FAILURE:-true}")
  NOTIFY_RESTORE_ON_SUCCESS=$(read_default "是否发送恢复成功通知 true/false" "${NOTIFY_RESTORE_ON_SUCCESS:-false}")
  NOTIFY_RESTORE_ON_FAILURE=$(read_default "是否发送恢复失败通知 true/false" "${NOTIFY_RESTORE_ON_FAILURE:-false}")
  local setting
  for setting in "$NOTIFY_ON_SUCCESS" "$NOTIFY_ON_FAILURE" "$NOTIFY_RESTORE_ON_SUCCESS" "$NOTIFY_RESTORE_ON_FAILURE"; do
    case "${setting,,}" in true|false|1|0|yes|no) ;; *) err "通知开关必须使用 true 或 false。"; return 1 ;; esac
  done
  vw_update_config_values "NOTIFY_METHOD=$NOTIFY_METHOD" "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}" "TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}" \
    "NTFY_URL=${NTFY_URL:-}" "NTFY_TOKEN=${NTFY_TOKEN:-}" "WEBHOOK_URL=${WEBHOOK_URL:-}" \
    "NOTIFY_ON_SUCCESS=$NOTIFY_ON_SUCCESS" "NOTIFY_ON_FAILURE=$NOTIFY_ON_FAILURE" \
    "NOTIFY_RESTORE_ON_SUCCESS=$NOTIFY_RESTORE_ON_SUCCESS" "NOTIFY_RESTORE_ON_FAILURE=$NOTIFY_RESTORE_ON_FAILURE" || { err "保存通知配置失败。"; return 1; }
  ok "通知配置已保存到权限为 600 的配置文件。"
  if [[ "$NOTIFY_METHOD" != none ]]; then
    if vw_notify success "Vaultwarden Backup Manager notification test from $(hostname)." true; then
      ok "测试通知已被服务端接受。"
    else
      err "测试通知发送失败；请检查接收 ID、凭据、URL 和网络。"
      return 1
    fi
  fi
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
    err "找不到诊断脚本。请从完整项目目录运行，或先选择菜单 [22] 同步后台脚本。"
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

performance_monitor() {
  local tool="$SCRIPT_DIR/vw-performance.py" choice perf_file="/var/lib/vaultwarden-backup/performance.tsv"
  [[ -f "$tool" ]] || tool="/usr/local/libexec/vw-performance.py"
  [[ -f "$tool" ]] || { err "找不到性能分析工具，请从项目目录运行菜单 [22]。"; pause; return 1; }
  if [[ ! -f "$perf_file" ]]; then
    warn "尚未找到性能记录文件：$perf_file"
    echo "systemd 自动备份使用系统安装版 worker，更新项目后请执行菜单 [22] 同步。"
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
        local out
        out="${BACKUP_DIR:-/var/backups/vaultwarden}/performance-$(date +%Y%m%d-%H%M%S).csv"
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
