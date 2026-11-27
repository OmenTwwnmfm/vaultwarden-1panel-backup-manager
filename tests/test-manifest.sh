#!/usr/bin/env bash
# The deployment manifest identifies 1Panel, docker compose and plain docker
# deployments and never records secret environment values.
set -Eeuo pipefail
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) echo "SKIP: manifest test needs a POSIX Python that can execute the fake docker script"; exit 0 ;;
esac
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"
PYTHON="$(command -v python || command -v python3)"
export PYTHONUTF8=1

cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
[[ "$1" == inspect ]] || exit 1
cat "$VW_TEST_FIXTURE"
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

fixture() {
  local name="$1" source="$2" labels="$3"
  cat > "$TMP/fixture.json" <<JSON
[{"Name": "/$name", "Image": "sha256:abc",
  "Config": {"Image": "vaultwarden/server:1.34.3",
             "Env": ["DOMAIN=https://vault.example", "ADMIN_TOKEN=fixture-value-one", "SMTP_PASSWORD=fixture-value-two"],
             "Labels": $labels},
  "HostConfig": {"RestartPolicy": {"Name": "unless-stopped"}, "PortBindings": {"80/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]}},
  "State": {"Status": "running", "Health": {"Status": "healthy"}},
  "NetworkSettings": {"Networks": {"bridge": {}}},
  "Mounts": [{"Type": "bind", "Source": "$source", "Destination": "/data", "RW": true}]}]
JSON
}

check() {
  local expected="$1" output="$TMP/manifest-$1.json"
  VW_TEST_FIXTURE="$TMP/fixture.json" "$PYTHON" -B "$ROOT/scripts/vw-manifest.py" vaultwarden "$output"
  "$PYTHON" - "$output" "$expected" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
assert manifest["manifest_format"] == 2, manifest["manifest_format"]
assert manifest["deployment"]["type"] == expected, manifest["deployment"]
notes = " ".join(manifest["recovery_notes"])
assert ("1Panel" in notes) == (expected == "1panel"), notes
assert ("compose" in notes) == (expected == "docker-compose"), notes
assert manifest["container"]["safe_environment"] == {"DOMAIN": "https://vault.example"}
assert manifest["container"]["omitted_environment_variable_names"] == ["ADMIN_TOKEN", "SMTP_PASSWORD"]
text = open(sys.argv[1], encoding="utf-8").read()
assert "fixture-value-one" not in text and "fixture-value-two" not in text
if expected == "docker-compose":
    assert manifest["deployment"]["compose_project"] == "vw"
    assert manifest["deployment"]["compose_service"] == "vaultwarden"
    assert manifest["deployment"]["compose_config_files"] == "/srv/vw/compose.yaml"
PY
}

fixture 1Panel-vaultwarden-Ab3d /opt/1panel/apps/vaultwarden/vaultwarden/data \
  '{"com.docker.compose.project": "1panel-vaultwarden", "com.docker.compose.project.working_dir": "/opt/1panel/apps/vaultwarden/vaultwarden"}'
check 1panel
fixture vw-vaultwarden-1 /srv/vw/data \
  '{"com.docker.compose.project": "vw", "com.docker.compose.service": "vaultwarden", "com.docker.compose.project.config_files": "/srv/vw/compose.yaml", "com.docker.compose.project.working_dir": "/srv/vw"}'
check docker-compose
fixture vaultwarden /var/lib/docker/volumes/vw-data/_data null
check docker
echo "PASS: manifest detects 1Panel, docker compose and docker run deployments without secret values"
