#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/backups" "$TMP/select"
export PYTHONUTF8=1
cat > "$TMP/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
exec python "$@"
PYTHON
chmod +x "$TMP/bin/python3"
PATH="$TMP/bin:$PATH"
export PATH
sed -n '/^choose_backup_name() {/,/^}/p; /^select_source_archive() {/,/^}/p' "$ROOT/scripts/vw-manager.sh" > "$TMP/functions.sh"
read_default() { local prompt="$1" default="$2" value; read -r value || true; printf '%s' "${value:-$default}"; }
err() { printf '%s\n' "$*" >&2; }
source "$TMP/functions.sh"
STORAGE_TOOL="$ROOT/scripts/vw-storage.py"
BACKUP_DIR="$TMP/backups"
name="pre-restore-20261122-131927-1244301.tar.gz.age"
printf 'age-encryption.org/v1\ntest ciphertext' > "$BACKUP_DIR/$name"
(cd "$BACKUP_DIR" && sha256sum "$name" > "$name.sha256")
select_source_archive local-fixed "$TMP/select" <<< '1'
[[ "$SELECTED_ARCHIVE" == "$BACKUP_DIR/$name" ]]
printf 'payload changed' >> "$SELECTED_ARCHIVE"
if select_source_archive local-fixed "$TMP/select" <<< '1'; then
  echo 'FAIL: selection accepted changed ciphertext' >&2
  exit 1
fi
printf '%s\n' "$name" > "$TMP/select/archives.txt"
if choose_backup_name "$TMP/select/archives.txt" <<< '999'; then
  echo 'FAIL: selection accepted an invalid index' >&2
  exit 1
fi
echo 'PASS: local rollback snapshots are selectable and checked through the manager entry point'
