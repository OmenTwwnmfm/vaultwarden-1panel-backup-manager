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

[[ -f "$ARCHIVE" ]] || { echo "错误：找不到备份文件：$ARCHIVE" >&2; exit 1; }
[[ -f "$IDENTITY" ]] || { echo "错误：找不到 age 私钥文件：$IDENTITY" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "错误：未安装 age。" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "错误：未安装 tar。" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "错误：未安装 sha256sum。" >&2; exit 1; }

CHECKSUM="${ARCHIVE}.sha256"
if [[ -f "$CHECKSUM" ]]; then
  echo "正在校验 SHA256..."
  (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$CHECKSUM")")
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
mkdir -p "$STAGING/data"
chmod 700 "$STAGING" "$STAGING/data"
LIST_FILE=$(mktemp "$STAGING/archive-list.XXXXXX")
cleanup() { rm -f -- "$LIST_FILE"; }
trap cleanup EXIT

# First decrypt pass only lists archive paths. Reject absolute paths and .. traversal.
echo "正在检查加密归档结构..."
if ! age -d -i "$IDENTITY" "$ARCHIVE" | tar -tzf - > "$LIST_FILE"; then
  echo "错误：age 解密或 tar 归档读取失败。" >&2
  exit 1
fi
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  if [[ "$entry" == /* ]]; then
    echo "错误：归档包含绝对路径，拒绝解压：$entry" >&2
    exit 1
  fi
  IFS='/' read -r -a parts <<< "$entry"
  for part in "${parts[@]}"; do
    if [[ "$part" == ".." ]]; then
      echo "错误：归档包含路径穿越项目，拒绝解压：$entry" >&2
      exit 1
    fi
  done
done < "$LIST_FILE"

# Second pass streams decrypted bytes directly into tar; no plaintext archive is left on disk.
echo "正在解密并解压到暂存目录..."
age -d -i "$IDENTITY" "$ARCHIVE" | tar --numeric-owner --same-owner -xzpf - -C "$STAGING/data"

[[ -f "$STAGING/data/db.sqlite3" ]] || {
  echo "错误：解压后没有发现 db.sqlite3。请勿恢复这份备份。" >&2
  exit 1
}

rm -f -- "$LIST_FILE"
trap - EXIT
echo "成功：备份已解密并解压到：$STAGING/data"
echo "此脚本不会覆盖 Vaultwarden 正在使用的数据目录。"
echo "恢复前必须停止目标容器，并保留当前 /data 目录副本。"
