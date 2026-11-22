#!/usr/bin/env bash
# Simple launcher for the interactive 1Panel Vaultwarden backup manager.
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MANAGER="$PROJECT_DIR/scripts/vw-manager.sh"
export VBM_PROJECT_ROOT="$PROJECT_DIR"

if [[ ! -t 0 && "${1:-}" != status ]]; then
  echo "错误：请在 SSH 终端或 1Panel 终端中交互式运行。" >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo env VBM_PROJECT_ROOT="$PROJECT_DIR" bash "$0" "$@"
  fi
  echo "错误：请使用 root 运行此脚本。" >&2
  exit 1
fi

unset VW_CONFIG_FILE VW_LOG_FILE VW_LOCK_FILE VW_STATE_DIR VW_COMMON_LIB VW_MANIFEST_TOOL VW_ARCHIVE_CHECK_TOOL VW_STORAGE_TOOL VW_ALLOW_UNSIGNED VW_MIN_FREE_MB VW_PERF_FILE VW_PERF_LOCK_FILE VW_DIAG_REPORT_DIR

check_root_owned_tree() {
  local path="$PROJECT_DIR" owner mode bad_entry
  while :; do
    read -r owner mode < <(stat -c '%u %a' -- "$path") || return 1
    [[ "$owner" == 0 ]] && (( (8#$mode & 022) == 0 )) || {
      echo "错误：项目路径必须由 root 所有且不可被组/其他用户写入：$path" >&2
      return 1
    }
    [[ "$path" == / ]] && break
    path=$(dirname -- "$path")
  done
  for path in "$PROJECT_DIR/scripts" "$PROJECT_DIR/.git"; do
    [[ -e "$path" ]] || continue
    bad_entry=$(find "$path" -xdev \( -type l -o ! -user root -o -perm /022 \) -print -quit 2>/dev/null)
    if [[ -n "$bad_entry" ]]; then
      echo "错误：拒绝 root 执行非 root 所有或可被修改的项目文件：$bad_entry" >&2
      return 1
    fi
  done
  bad_entry=$(find "$PROJECT_DIR" -maxdepth 1 \( -type l -o \( -type f \( ! -user root -o -perm /022 \) \) \) -print -quit 2>/dev/null)
  if [[ -n "$bad_entry" ]]; then
    echo "错误：拒绝 root 执行非 root 所有或可被修改的项目文件：$bad_entry" >&2
    return 1
  fi
}

check_root_owned_tree || exit 1

for required in "$MANAGER" "$PROJECT_DIR/scripts/vw-common.sh" "$PROJECT_DIR/scripts/vw-maintenance.sh" "$PROJECT_DIR/scripts/vw-backup.sh" "$PROJECT_DIR/scripts/vw-restore-prepare.sh" "$PROJECT_DIR/scripts/vw-archive-check.py" "$PROJECT_DIR/scripts/vw-manifest.py" "$PROJECT_DIR/scripts/vw-storage.py" "$PROJECT_DIR/scripts/vw-diagnose.sh" "$PROJECT_DIR/scripts/vw-performance.py" "$PROJECT_DIR/scripts/vbm-launcher.sh"; do
  if [[ ! -f "$required" ]]; then
    echo "错误：项目文件不完整，缺少：$required" >&2
    echo "请从 GitHub 下载/克隆完整项目目录，不要只下载 run.sh。" >&2
    exit 1
  fi
done

if [[ "${1:-}" == status ]]; then exec bash "$MANAGER" "$@"; fi

# Self-heal the global command. This makes `vbm` available even if the first
# setup wizard or the previous script-update step did not install it.
install_vbm_command() {
  local launcher_tmp
  command -v python3 >/dev/null 2>&1 || { echo "提示：未找到 python3，暂时无法安装全局 vbm 命令。" >&2; return 1; }
  install -d -o root -g root -m 755 /usr/local/bin
  launcher_tmp=$(mktemp)
  python3 - "$PROJECT_DIR/scripts/vbm-launcher.sh" "$launcher_tmp" "$PROJECT_DIR/run.sh" <<'PYVBM'
from pathlib import Path
import shlex, sys
source, target, runner = sys.argv[1:]
content = Path(source).read_text(encoding="utf-8")
content = content.replace("__VBM_PROJECT_RUNNER__", shlex.quote(str(Path(runner).resolve())))
Path(target).write_text(content, encoding="utf-8")
PYVBM
  chmod 755 "$launcher_tmp"
  install -o root -g root -m 755 "$launcher_tmp" /usr/local/bin/vbm
  rm -f "$launcher_tmp"
  # Some minimal VPS images omit /usr/local/bin from root's PATH. Add a safe
  # /usr/bin shim only in that case, without replacing an existing command.
  case ":${PATH}:" in
    *:/usr/local/bin:*) ;;
    *)
      if [[ ":${PATH}:" == *:/usr/bin:* && ! -e /usr/bin/vbm ]]; then
        ln -s /usr/local/bin/vbm /usr/bin/vbm
      fi
      ;;
  esac
}

if ! install_vbm_command; then
  echo "警告：全局命令 vbm 安装失败；仍可通过 bash '$PROJECT_DIR/run.sh' 启动管理器。" >&2
else
  echo "全局命令已就绪：vbm"
fi

exec bash "$MANAGER" "$@"
