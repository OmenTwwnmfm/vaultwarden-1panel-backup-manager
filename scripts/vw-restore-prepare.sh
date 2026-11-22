#!/usr/bin/env bash
# Verify and decrypt a Vaultwarden age archive into a staging directory.
# No plaintext .tar.gz file is written to disk.
set -Eeuo pipefail
umask 077

usage() {
  echo "用法：$0 /path/to/vw-YYYYMMDD-HHMMSS.tar.gz.age /path/to/vw-age-identity.txt /path/to/empty-staging-dir"
  exit 2
}

[[ $# -eq 3 ]] || usage
ARCHIVE=$(readlink -f -- "$1")
IDENTITY=$(readlink -f -- "$2")
STAGING="$3"
ARCHIVE_CHECK_TOOL="${VW_ARCHIVE_CHECK_TOOL:-$(dirname -- "${BASH_SOURCE[0]}")/vw-archive-check.py}"
[[ -f "$ARCHIVE_CHECK_TOOL" ]] || ARCHIVE_CHECK_TOOL="/usr/local/libexec/vw-archive-check.py"
STORAGE_TOOL="${VW_STORAGE_TOOL:-$(dirname -- "${BASH_SOURCE[0]}")/vw-storage.py}"
[[ -f "$STORAGE_TOOL" ]] || STORAGE_TOOL="/usr/local/libexec/vw-storage.py"
[[ -f "$STORAGE_TOOL" ]] || { echo "错误：找不到备份校验工具 vw-storage.py。请从完整项目目录运行菜单 07 更新后台脚本。" >&2; exit 1; }

[[ -f "$ARCHIVE" ]] || { echo "错误：找不到备份文件：$ARCHIVE" >&2; exit 1; }
[[ -f "$IDENTITY" ]] || { echo "错误：找不到 age 私钥文件：$IDENTITY" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "错误：未安装 age。" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "错误：未安装 tar。" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "错误：未安装 sha256sum。" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "错误：恢复前必须安装 sqlite3，以执行数据库完整性检查。" >&2; exit 1; }
[[ -f "$ARCHIVE_CHECK_TOOL" ]] || { echo "错误：找不到归档安全检查工具：$ARCHIVE_CHECK_TOOL" >&2; exit 1; }

CHECKSUM="${ARCHIVE}.sha256"
if [[ -f "$CHECKSUM" ]]; then
  echo "正在校验 SHA256..."
  python3 "$STORAGE_TOOL" verify "$ARCHIVE"
else
  echo "错误：找不到配套 SHA256 文件：$CHECKSUM" >&2
  echo "为避免恢复不完整或被替换的文件，本脚本要求备份文件和 .sha256 同时存在。" >&2
  exit 1
fi

if [[ -e "$STAGING" ]]; then
  echo "错误：暂存目录已存在：$STAGING" >&2
  echo "请为本次恢复选择一个全新的目录。" >&2
  exit 1
fi
echo "正在验证加密归档结构和安全路径..."
if ! ARCHIVE_DATA_BYTES=$(age -d -i "$IDENTITY" "$ARCHIVE" | python3 "$ARCHIVE_CHECK_TOOL"); then
  echo "错误：age 解密、tar 完整性或归档路径安全检查失败。" >&2
  exit 1
fi
[[ "$ARCHIVE_DATA_BYTES" =~ ^[0-9]+$ ]] || { echo "错误：无法确定归档展开后的数据大小。" >&2; exit 1; }
MIN_FREE_MB="${VW_MIN_FREE_MB:-512}"
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || { echo "错误：恢复空间阈值配置无效。" >&2; exit 1; }
STAGING_PARENT=$(dirname -- "$STAGING")
[[ -d "$STAGING_PARENT" ]] || { echo "错误：恢复暂存目录的父目录不存在：$STAGING_PARENT" >&2; exit 1; }
AVAILABLE_BYTES=$(df -PB1 -- "$STAGING_PARENT" | awk 'NR == 2 {print $4}')
REQUIRED_BYTES=$((ARCHIVE_DATA_BYTES + MIN_FREE_MB * 1024 * 1024))
if [[ ! "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] || (( AVAILABLE_BYTES < REQUIRED_BYTES )); then
  echo "错误：恢复暂存分区空间不足。展开数据约 ${ARCHIVE_DATA_BYTES} bytes，另需保留 ${MIN_FREE_MB} MiB 可用空间。" >&2
  exit 1
fi

mkdir -p "$STAGING/data"
chmod 700 "$STAGING" "$STAGING/data"

# Second pass streams decrypted bytes directly into tar; no plaintext archive is left on disk.
echo "正在解密并解压到暂存目录..."
age -d -i "$IDENTITY" "$ARCHIVE" | tar --numeric-owner --same-owner -xzpf - -C "$STAGING/data"

[[ -s "$STAGING/data/db.sqlite3" ]] || {
  echo "错误：解压后没有发现非空 db.sqlite3。请勿恢复这份备份。" >&2
  exit 1
}
SQLITE_RESULT=$(sqlite3 -readonly "$STAGING/data/db.sqlite3" 'PRAGMA quick_check;' 2>&1) || {
  echo "错误：恢复暂存数据库 quick_check 执行失败：$SQLITE_RESULT" >&2
  exit 1
}
[[ "$SQLITE_RESULT" == "ok" ]] || {
  echo "错误：恢复暂存数据库完整性检查未通过：$SQLITE_RESULT" >&2
  exit 1
}
echo "SQLite quick_check：OK"

echo "成功：备份已解密并解压到：$STAGING/data"
echo "此脚本不会覆盖 Vaultwarden 正在使用的数据目录。"
echo "恢复前必须停止目标容器，并保留当前 /data 目录副本。"
