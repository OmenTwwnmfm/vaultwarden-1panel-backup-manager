#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/scripts/vw-common.sh"
source "$ROOT/scripts/manager-ops.sh"
source "$ROOT/scripts/manager-restore.sh"
REAL_PYTHON="$(command -v python || command -v python3)"
export PYTHONUTF8=1
export VW_TEST_MESSAGES="$TMP/messages"
: > "$VW_TEST_MESSAGES"
CONFIG_FILE="$TMP/backup.conf"
vw_require_secure_config() { return 0; }

harness=$(cat <<'PY'
from io import BytesIO
import json, os, secrets, sys, time
import urllib.error, urllib.parse, urllib.request

scenario = os.environ.get("VW_TEST_SCENARIO", "")
mode, *args = sys.argv[1:]
if mode == "-c":
    script = args[0]
    token = "123:fixture-token"
    secrets.token_hex = lambda _: "0123456789abcdef"
    challenge = "vbm-0123456789abcdef"
    updates = [
        {"message": {"text": "old message", "chat": {"type": "private", "id": 111}}},
        {"message": {"text": challenge, "chat": {"type": "group", "id": -222}}},
    ]
    if scenario in ("paired", "ambiguous"):
        updates.append({"message": {"text": challenge, "chat": {"type": "private", "id": 333}}})
    if scenario == "ambiguous":
        updates.append({"message": {"text": challenge, "chat": {"type": "private", "id": 444}}})
    mock_time = iter((0, 1, 121))
    time.monotonic = lambda: next(mock_time)
    time.sleep = lambda _: None

    class Opener:
        def open(self, url, data, timeout):
            assert url == "https://api.telegram.org/bot" + token + "/getUpdates"
            assert "offset" not in urllib.parse.parse_qs(data.decode())
            if scenario == "conflict":
                raise urllib.error.HTTPError(url, 409, "Conflict", {}, None)
            if scenario == "network":
                raise urllib.error.URLError("must not print " + token)
            return BytesIO(json.dumps({"ok": True, "result": updates}).encode())

    urllib.request.build_opener = lambda *handlers: Opener()
else:
    assert mode == "-"
    script = sys.stdin.read()
    sys.argv = [mode] + args

    class Response(BytesIO):
        status = 204

    def capture(req, timeout):
        assert req.full_url == "https://example.invalid/vbm"
        with open(os.environ["VW_TEST_MESSAGES"], "a", encoding="utf-8", newline="\n") as output:
            output.write(json.loads(req.data)["event"] + "\n")
        return Response()

    urllib.request.urlopen = capture

exec(compile(script, "<notification>", "exec"))
PY
)
python3() { "$REAL_PYTHON" -c "$harness" "$@"; }

token=123:fixture-token
chat_id=$(VW_TEST_SCENARIO=paired vw_telegram_chat_id <<<"$token" 2> "$TMP/stderr")
[[ "$chat_id" == 333 ]]
grep -Fq 'vbm-0123456789abcdef' "$TMP/stderr"
for scenario in ambiguous conflict network timeout; do
  if VW_TEST_SCENARIO="$scenario" vw_telegram_chat_id <<<"$token" > "$TMP/stdout" 2> "$TMP/stderr"; then exit 1; fi
  [[ ! -s "$TMP/stdout" ]]
  if grep -Fq -- "$token" "$TMP/stderr"; then exit 1; fi
done
if vw_telegram_chat_id <<<'invalid' > "$TMP/stdout" 2> "$TMP/stderr"; then exit 1; fi
grep -Fq '格式无效' "$TMP/stderr"

printf '%s\n' 'NOTIFY_METHOD=webhook' 'WEBHOOK_URL=https://example.invalid/vbm' > "$CONFIG_FILE"
vw_notify success 'backup completed'
vw_notify failure 'backup failed'
vw_notify success 'restore completed' false restore
vw_notify failure 'restore failed' false restore
[[ "$(<"$VW_TEST_MESSAGES")" == $'success\nfailure' ]]
printf '%s\n' 'NOTIFY_ON_SUCCESS=false' 'NOTIFY_ON_FAILURE=false' 'NOTIFY_RESTORE_ON_SUCCESS=true' 'NOTIFY_RESTORE_ON_FAILURE=true' >> "$CONFIG_FILE"
vw_notify success 'backup completed'
vw_notify failure 'backup failed'
vw_notify success 'restore completed' false restore
vw_notify failure 'restore failed' false restore
vw_notify success 'forced test' true
[[ "$(<"$VW_TEST_MESSAGES")" == $'success\nfailure\nrestore_success\nrestore_failure\nsuccess' ]]

(
  load_config() {
    NOTIFY_METHOD=none
    TELEGRAM_CHAT_ID="${VW_TEST_CHAT_ID:-}"
    TELEGRAM_BOT_TOKEN="${VW_TEST_TOKEN:-}"
  }
  read_default() { local answer; read -r answer; printf '%s\n' "${answer:-$2}"; }
  ok() { :; }
  err() { printf '%s\n' "$*" >&2; }
  pause() { :; }
  vw_update_config_values() { printf '%s\n' "$@" > "$TMP/settings"; }
  vw_notify() { [[ "$3" == true ]]; }
  VW_TEST_SCENARIO=paired configure_notifications <<< $'telegram\n123:fixture-token\nfalse\ntrue\ntrue\nfalse'
  grep -Fxq 'TELEGRAM_CHAT_ID=333' "$TMP/settings"
  grep -Fxq 'NOTIFY_RESTORE_ON_SUCCESS=true' "$TMP/settings"
  VW_TEST_TOKEN="$token" VW_TEST_CHAT_ID=222 configure_notifications <<< $'telegram\n\n\n\n\ntrue'
  grep -Fxq 'TELEGRAM_CHAT_ID=222' "$TMP/settings"
  grep -Fxq 'NOTIFY_RESTORE_ON_FAILURE=true' "$TMP/settings"
  cp "$TMP/settings" "$TMP/prior"
  if VW_TEST_SCENARIO=network configure_notifications <<< $'telegram\n123:fixture-token'; then exit 1; fi
  cmp "$TMP/prior" "$TMP/settings"
)

(
  cleanup_restore() { printf 'cleanup:%s\n' "$1" >> "$TMP/restore-events"; }
  vw_notify() { printf 'notify:%s:%s\n' "$1" "$4" >> "$TMP/restore-events"; return 1; }
  pause() { printf 'pause\n' >> "$TMP/restore-events"; }
  require_docker() { return 1; }
  if restore_from_github local; then exit 1; else [[ "$?" == 1 ]]; fi
  (trap 'finish_restore "$?" "" "" "" 0 0 0 "" ""' EXIT; exit 0)
  (trap 'finish_restore "$?" healthy backup.age vaultwarden 0 1 0 "" ""' EXIT; exit 0)
  [[ "$(<"$TMP/restore-events")" == $'cleanup:1\nnotify:failure:restore\ncleanup:0\ncleanup:0\nnotify:success:restore\npause' ]]
)
echo 'PASS: Telegram pairing, legacy settings, four notification switches and restore outcomes'
