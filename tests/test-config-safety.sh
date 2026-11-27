#!/usr/bin/env bash
# Config writes are serialized and partial, notification URLs require HTTPS,
# and the Git repository size helper reports the object store.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/etc"
VW_TEST_REAL_PYTHON="$(command -v python || command -v python3)"
export VW_TEST_REAL_PYTHON
cat > "$TMP/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
exec "$VW_TEST_REAL_PYTHON" "$@"
PYTHON
chmod +x "$TMP/bin/python3"
command -v flock >/dev/null 2>&1 || { printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/flock"; chmod +x "$TMP/bin/flock"; }
PATH="$TMP/bin:$PATH"
export PATH PYTHONUTF8=1
# shellcheck disable=SC1091
source "$ROOT/scripts/vw-common.sh"

# The tests do not run as root: present the temporary files as root-owned.
real_stat=$(command -v stat)
stat() {
  if [[ "$1" == -c && ( "$2" == '%u' || "$2" == '%u:%a' ) ]]; then
    local format="$2"
    shift 2
    [[ "${1:-}" != -- ]] || shift
    if [[ "$format" == '%u:%a' ]]; then printf '0:%s\n' "$("$real_stat" -c '%a' -- "$1")"; else printf '0\n'; fi
    return 0
  fi
  "$real_stat" "$@"
}
chown() { return 0; }
# Windows Python (Git Bash) cannot fsync a directory; Linux CI uses the real helper.
[[ "$(uname -s)" == Linux ]] || vw_atomic_replace() { mv -- "$1" "$2"; }
chmod 700 "$TMP/etc"

CONFIG_FILE="$TMP/etc/vaultwarden-backup.conf"
export VW_CONFIG_LOCK_FILE="$TMP/config.lock"
printf 'CONTAINER=old\nDATA_DIR=/srv/data\nNOTIFY_METHOD=ntfy\nNTFY_URL=https://ntfy.example/topic\nRETENTION_DAYS=30\n' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
modes_supported=true
if [[ "$("$real_stat" -c '%a' "$CONFIG_FILE")" != 600 ]]; then
  # Filesystems without POSIX modes (e.g. Git Bash on NTFS) cannot hold 600;
  # the permission check itself is covered on Linux CI.
  modes_supported=false
  vw_require_secure_config() { return 0; }
fi

# A menu save that changed RETENTION_DAYS while a worker still holds stale
# values must not be lost when the worker records a new container name.
# shellcheck disable=SC2034 # stale caller values that vw_update_config_values must not write back
CONTAINER=old RETENTION_DAYS=30 NTFY_URL=https://ntfy.example/topic
printf 'CONTAINER=old\nDATA_DIR=/srv/data\nNOTIFY_METHOD=ntfy\nNTFY_URL=https://ntfy.example/topic\nRETENTION_DAYS=90\n' > "$CONFIG_FILE"
vw_update_config_values "CONTAINER=new-container" "DATA_DIR=/srv/data"
grep -Fxq 'CONTAINER=new-container' "$CONFIG_FILE" || { echo "FAIL: container was not updated" >&2; exit 1; }
grep -Fxq 'RETENTION_DAYS=90' "$CONFIG_FILE" || { echo "FAIL: concurrent menu setting was overwritten" >&2; cat "$CONFIG_FILE" >&2; exit 1; }
grep -Fxq 'NTFY_URL=https://ntfy.example/topic' "$CONFIG_FILE"
[[ "$CONTAINER" == old ]] || { echo "FAIL: partial update leaked into the caller shell" >&2; exit 1; }
[[ "$modes_supported" == false || "$("$real_stat" -c '%a' "$CONFIG_FILE")" == 600 ]] || { echo "FAIL: config mode is not 600" >&2; exit 1; }
if vw_update_config_values "NOT_A_SETTING=1" 2>/dev/null; then echo "FAIL: unknown key accepted" >&2; exit 1; fi
if vw_update_config_values "CONTAINER" 2>/dev/null; then echo "FAIL: assignment without value accepted" >&2; exit 1; fi
value_with_space='a b $(touch '"$TMP"'/pwned)'
vw_update_config_values "CONTAINER_MATCH=$value_with_space"
# shellcheck source=/dev/null
( set +u; source "$CONFIG_FILE"; [[ "$CONTAINER_MATCH" == "$value_with_space" ]] ) || { echo "FAIL: value was not shell-escaped" >&2; exit 1; }
[[ ! -e "$TMP/pwned" ]] || { echo "FAIL: config value was executed" >&2; exit 1; }
echo "PASS: partial config updates preserve concurrent settings and stay escaped"

for url in https://ntfy.sh/topic https://hooks.example.com:8443/path http://localhost:8080/hook http://127.0.0.1/x 'http://[::1]:9000/'; do
  vw_notify_url_allowed "$url" || { echo "FAIL: rejected $url" >&2; exit 1; }
done
for url in http://ntfy.sh/topic http://192.168.1.2/hook 'http://localhost.evil.example/x' ftp://example.com/ https:// ''; do
  if vw_notify_url_allowed "$url"; then echo "FAIL: accepted $url" >&2; exit 1; fi
done
printf 'NOTIFY_METHOD=webhook\nWEBHOOK_URL=http://hooks.example.com/x\n' > "$CONFIG_FILE"
if notify_output=$(vw_notify failure "test message" 2>&1); then echo "FAIL: plain HTTP webhook was used" >&2; exit 1; fi
grep -Fq 'must use https://' <<<"$notify_output" || { echo "FAIL: HTTPS rejection reason missing: $notify_output" >&2; exit 1; }
# A config without NOTIFY_ON_FAILURE (older releases) must still send
# failure alerts. Port 9 on localhost refuses the connection, so a send
# attempt fails loudly instead of being silently skipped.
printf 'NOTIFY_METHOD=webhook\nWEBHOOK_URL=http://127.0.0.1:9/hook\n' > "$CONFIG_FILE"
if notify_output=$(vw_notify failure "test message" 2>&1); then echo "FAIL: failure alert was skipped when NOTIFY_ON_FAILURE is unset" >&2; exit 1; fi
grep -Fq 'Notification failed' <<<"$notify_output" || { echo "FAIL: no send attempt: $notify_output" >&2; exit 1; }
printf 'NOTIFY_METHOD=webhook\nWEBHOOK_URL=http://127.0.0.1:9/hook\nNOTIFY_ON_FAILURE=false\n' > "$CONFIG_FILE"
vw_notify failure "test message" || { echo "FAIL: NOTIFY_ON_FAILURE=false did not disable failure alerts" >&2; exit 1; }
echo "PASS: notification URLs require HTTPS except on localhost"

git init --quiet "$TMP/repo"
git -C "$TMP/repo" config user.name Tester
git -C "$TMP/repo" config user.email test@example.invalid
head -c 300000 /dev/urandom > "$TMP/repo/blob.bin"
git -C "$TMP/repo" add blob.bin
git -C "$TMP/repo" commit --quiet -m blob
git -C "$TMP/repo" rm --quiet blob.bin
git -C "$TMP/repo" commit --quiet -m 'remove blob'
kib=$(vw_git_repo_kib "$TMP/repo")
(( kib >= 250 )) || { echo "FAIL: deleted blob not counted in repository size ($kib KiB)" >&2; exit 1; }
git -C "$TMP/repo" gc --quiet
kib=$(vw_git_repo_kib "$TMP/repo")
(( kib >= 250 )) || { echo "FAIL: packed objects not counted ($kib KiB)" >&2; exit 1; }
if vw_git_repo_kib "$TMP/missing" >/dev/null; then echo "FAIL: missing repository accepted" >&2; exit 1; fi
echo "PASS: repository size includes history that deleting files does not reclaim"
