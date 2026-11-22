#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/input"
printf 'db fixture\n' > "$TMP/input/db.sqlite3"
printf 'key fixture\n' > "$TMP/identity"
archive_name=vw-20261122-000001.tar.gz.age
{ printf 'age-encryption.org/v1\n'; tar -czf - -C "$TMP/input" .; } > "$TMP/$archive_name"
(cd "$TMP" && sha256sum "$archive_name" > "$archive_name.sha256")

cat > "$TMP/bin/age" <<'AGE'
#!/usr/bin/env bash
tail -n +2 -- "$4"
AGE
cat > "$TMP/bin/sqlite3" <<'SQLITE'
#!/usr/bin/env bash
if [[ "$VW_TEST_FAIL" == sqlite ]]; then echo 'database not ok'; else echo ok; fi
SQLITE
cat > "$TMP/bin/tar" <<'TAR'
#!/usr/bin/env bash
set -e
"$VW_TEST_REAL_TAR" "$@"
case "$VW_TEST_FAIL" in
  tar) exit 1 ;;
  term) kill -TERM "$PPID" ;;
  interrupt) kill -INT "$PPID" ;;
esac
TAR
cat > "$TMP/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
exec python "$@"
PYTHON
export VW_TEST_REAL_TAR="$(command -v tar)" PYTHONUTF8=1
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
for scenario in tar sqlite term interrupt success; do
  if [[ "$scenario" == term || "$scenario" == interrupt ]] && [[ "$(uname -s)" != Linux ]]; then continue; fi
  result=0
  VW_TEST_FAIL="$scenario" VW_MIN_FREE_MB=0 VW_ALLOW_UNSIGNED=1 bash "$ROOT/scripts/vw-restore-prepare.sh" "$TMP/$archive_name" "$TMP/identity" "$TMP/$scenario" > "$TMP/log" 2>&1 || result=$?
  if [[ "$scenario" == success ]]; then
    [[ "$result" == 0 && -f "$TMP/$scenario/data/db.sqlite3" ]] || { cat "$TMP/log"; exit 1; }
  else
    [[ "$result" != 0 && ! -e "$TMP/$scenario" ]] || { cat "$TMP/log"; exit 1; }
    if [[ "$scenario" == term ]]; then [[ "$result" == 143 ]]; fi
    if [[ "$scenario" == interrupt ]]; then [[ "$result" == 130 ]]; fi
  fi
done
mkdir "$TMP/existing"
touch "$TMP/existing/preserve"
if VW_TEST_FAIL=none bash "$ROOT/scripts/vw-restore-prepare.sh" "$TMP/$archive_name" "$TMP/identity" "$TMP/existing" > "$TMP/log" 2>&1; then exit 1; fi
[[ -f "$TMP/existing/preserve" ]]
echo 'PASS: restore failures clean only their own staging directory'
