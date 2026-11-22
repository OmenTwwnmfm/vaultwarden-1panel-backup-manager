#!/usr/bin/env bash
# Installed by Vaultwarden 1Panel Backup Manager as /usr/local/bin/vbm.
set -Eeuo pipefail
PROJECT_RUNNER=__VBM_PROJECT_RUNNER__
if [[ ! -f "$PROJECT_RUNNER" ]]; then
  echo "错误：找不到项目启动器：$PROJECT_RUNNER" >&2
  echo "请重新克隆项目，并重新运行：sudo bash ./run.sh" >&2
  exit 1
fi
PROJECT_ROOT=$(dirname -- "$PROJECT_RUNNER")
check_project_tree() {
  local path="$PROJECT_ROOT" owner mode bad_entry
  while :; do
    read -r owner mode < <(stat -c '%u %a' -- "$path") || return 1
    [[ "$owner" == 0 ]] && (( (8#$mode & 022) == 0 )) || {
      echo "错误：vbm 项目路径必须由 root 所有且不可被组/其他用户写入：$path" >&2
      return 1
    }
    [[ "$path" == / ]] && break
    path=$(dirname -- "$path")
  done
  for path in "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/.git"; do
    [[ -e "$path" ]] || continue
    bad_entry=$(find "$path" -xdev \( -type l -o ! -user root -o -perm /022 \) -print -quit 2>/dev/null)
    if [[ -n "$bad_entry" ]]; then
      echo "错误：拒绝执行不安全的 vbm 项目文件：$bad_entry" >&2
      return 1
    fi
  done
  bad_entry=$(find "$PROJECT_ROOT" -maxdepth 1 \( -type l -o \( -type f \( ! -user root -o -perm /022 \) \) \) -print -quit 2>/dev/null)
  if [[ -n "$bad_entry" ]]; then
    echo "错误：拒绝执行不安全的 vbm 项目文件：$bad_entry" >&2
    return 1
  fi
}
check_project_tree || exit 1
if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "错误：需要 root 权限，且系统没有 sudo。请使用 root 运行 vbm。" >&2
    exit 1
  fi
  exec sudo env VBM_PROJECT_ROOT="$PROJECT_ROOT" bash "$PROJECT_RUNNER" "$@"
fi
exec bash "$PROJECT_RUNNER" "$@"
