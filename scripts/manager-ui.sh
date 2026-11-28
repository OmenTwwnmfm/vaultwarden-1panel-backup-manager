#!/usr/bin/env bash
# shellcheck shell=bash
# Terminal UI helpers: messages, confirmations, prompts and environment guards.
# Sourced by vw-manager.sh through vbm_source_trusted; relies on its globals and helpers.

info() { printf "${BLUE}[信息]${NC} %s\n" "$*"; }

ok() { printf "${GREEN}[完成]${NC} %s\n" "$*"; }

warn() { printf "${YELLOW}[注意]${NC} %s\n" "$*"; }

err() { printf "${RED}[错误]${NC} %s\n" "$*" >&2; }

pause() { read -r -p $'\n按 Enter 返回菜单... ' _ || true; }

confirm_yes() {
  local prompt="$1" answer
  printf '\n%s\n' "$prompt"
  vw_perf_user_wait_begin
  read -r -p "输入 yes 继续（其他输入均取消）: " answer || true
  vw_perf_user_wait_end
  [[ "${answer,,}" == "yes" ]]
}

confirm_yes_upper() {
  # Keep the historical function name for compatibility, but accept YES in
  # any letter case. This is case-insensitive, not a single-key confirmation.
  local prompt="$1" answer
  printf '\n%s\n' "$prompt"
  vw_perf_user_wait_begin
  read -r -p "这是有风险的操作。输入 yes 确认（大小写不敏感，例如 yes / YES / Yes）: " answer || true
  vw_perf_user_wait_end
  [[ "${answer,,}" == "yes" ]]
}

read_default() {
  local prompt="$1" default="$2" value
  vw_perf_user_wait_begin
  read -r -p "$prompt [$default]: " value || true
  vw_perf_user_wait_end
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
    err "没有找到 docker 命令。请先安装 Docker（可由 1Panel 管理，也可独立安装）。"
    return 1
  fi
}
