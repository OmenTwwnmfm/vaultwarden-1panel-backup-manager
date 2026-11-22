#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/data"
printf 'db' > "$TMP/data/db.sqlite3"
printf 'restarting\n' > "$TMP/state"
printf '1\n' > "$TMP/count"

cat > "$TMP/bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  ps)
    count=$(cat "$VW_TEST_COUNT")
    for ((index=1; index<=count; index++)); do printf 'id%s\n' "$index"; done
    ;;
  inspect)
    if [[ "${2:-}" == -f ]]; then
      format="$3"; container="$4"
    else
      container="$2"; format="$4"
    fi
    case "$format" in
      *'.Name'*) printf '/container%s\n' "${container#id}" ;;
      *'.Config.Image'*) printf 'vaultwarden/server:test\n' ;;
      *'.State.Status'*) cat "$VW_TEST_STATE" ;;
      *'.State.Health'*) printf 'healthy\n' ;;
      *'.Mounts'*) printf '%s\n' "$VW_TEST_DATA" ;;
      *) echo "unexpected inspect template: $format" >&2; exit 2 ;;
    esac
    ;;
  stop)
    printf 'exited\n' > "$VW_TEST_STATE"
    ;;
  unpause)
    printf 'running\n' > "$VW_TEST_STATE"
    ;;
  *) echo "unexpected docker command: $*" >&2; exit 2 ;;
esac
FAKEDOCKER
chmod +x "$TMP/bin/docker"
PATH="$TMP/bin:$PATH"
export PATH
export VW_TEST_STATE="$TMP/state" VW_TEST_COUNT="$TMP/count" VW_TEST_DATA="$TMP/data"
# shellcheck disable=SC1091
source "$ROOT/scripts/vw-common.sh"

vw_ensure_target_stopped old-container "$TMP/data" 1
[[ "$VW_DETECTED_CONTAINER" == container1 ]]
[[ "$VW_DETECTED_STATUS" == exited ]]
[[ "$VW_CONTAINER_STOPPED_BY_HELPER" == 1 ]]

printf 'paused\n' > "$VW_TEST_STATE"
vw_ensure_target_stopped container1 "$TMP/data" 1
[[ "$(cat "$VW_TEST_STATE")" == exited ]]

printf 'unknown\n' > "$VW_TEST_STATE"
if vw_ensure_target_stopped container1 "$TMP/data" 1; then
  echo "FAIL: unknown status was accepted" >&2
  exit 1
fi

printf 'exited\n' > "$VW_TEST_STATE"
printf '2\n' > "$VW_TEST_COUNT"
if vw_ensure_target_stopped container1 "$TMP/data" 1; then
  echo "FAIL: ambiguous shared data mount was accepted" >&2
  exit 1
fi

echo "PASS: stop guard handles restarting/paused states and rejects unknown or ambiguous targets"
