#!/usr/bin/env bash
# Simple launcher for the interactive 1Panel Vaultwarden backup manager.
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANAGER="$PROJECT_DIR/scripts/vw-manager.sh"

if [[ ! -t 0 ]]; then
  echo "错误：请在 SSH 终端或 1Panel 终端中交互式运行。" >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  echo "错误：请使用 root 运行此脚本。" >&2
  exit 1
fi

for required in "$MANAGER" "$PROJECT_DIR/scripts/vw-backup.sh" "$PROJECT_DIR/scripts/vw-restore-prepare.sh"; do
  if [[ ! -f "$required" ]]; then
    echo "错误：项目文件不完整，缺少：$required" >&2
    echo "请从 GitHub 下载/克隆完整项目目录，不要只下载 run.sh。" >&2
    exit 1
  fi
done

exec bash "$MANAGER" "$@"
