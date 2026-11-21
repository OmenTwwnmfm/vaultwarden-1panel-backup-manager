#!/usr/bin/env bash
# Installed by Vaultwarden 1Panel Backup Manager as /usr/local/bin/vbm.
set -Eeuo pipefail
PROJECT_RUNNER=__VBM_PROJECT_RUNNER__
if [[ ! -f "$PROJECT_RUNNER" ]]; then
  echo "错误：找不到项目启动器：$PROJECT_RUNNER" >&2
  echo "请重新克隆项目，或从项目目录运行 bash ./run.sh 完成安装。" >&2
  exit 1
fi
if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "错误：需要 root 权限，且系统没有 sudo。请使用 root 运行 vbm。" >&2
    exit 1
  fi
  exec sudo -E bash "$PROJECT_RUNNER" "$@"
fi
exec bash "$PROJECT_RUNNER" "$@"
