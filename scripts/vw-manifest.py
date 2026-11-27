#!/usr/bin/env python3
"""Create a sanitized, non-secret deployment manifest from docker inspect."""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

if len(sys.argv) != 3:
    print("usage: vw-manifest.py CONTAINER OUTPUT.json", file=sys.stderr)
    raise SystemExit(2)
container, output = sys.argv[1:]
try:
    raw = subprocess.check_output(["docker", "inspect", "--type", "container", "--", container], text=True, stderr=subprocess.DEVNULL)
    obj = json.loads(raw)[0]
except (OSError, subprocess.CalledProcessError, ValueError, IndexError, KeyError, AttributeError, TypeError):
    print("无法读取 Vaultwarden 容器配置，请确认容器仍在 Docker 中。", file=sys.stderr)
    raise SystemExit(1)
config = obj.get("Config") or {}
host = obj.get("HostConfig") or {}
state = obj.get("State") or {}
network_settings = obj.get("NetworkSettings") or {}

safe_env = {
    "DOMAIN", "SIGNUPS_ALLOWED", "INVITATIONS_ALLOWED", "SHOW_PASSWORD_HINT",
    "EMERGENCY_ACCESS_ALLOWED", "ORG_GROUPS_ENABLED", "PUSH_ENABLED",
    "WEBSOCKET_ENABLED", "TZ", "LOG_LEVEL", "EXTENDED_LOGGING",
}
env_values = {}
redacted_names = []
for item in config.get("Env") or []:
    if "=" not in item:
        continue
    key, value = item.split("=", 1)
    if key in safe_env:
        env_values[key] = value
    else:
        # Record variable names only; arbitrary values may contain secrets.
        redacted_names.append(key)

mounts = []
for mount in obj.get("Mounts") or []:
    mounts.append({
        "type": mount.get("Type"),
        "source": mount.get("Source"),
        "destination": mount.get("Destination"),
        "read_only": not bool(mount.get("RW", True)),
    })

ports = {}
for container_port, bindings in (host.get("PortBindings") or {}).items():
    ports[container_port] = [
        {"host_ip": b.get("HostIp"), "host_port": b.get("HostPort")}
        for b in (bindings or [])
    ]

networks = sorted((network_settings.get("Networks") or {}).keys())
labels = config.get("Labels") or {}
name = (obj.get("Name") or "").lstrip("/")
compose_project = labels.get("com.docker.compose.project")
compose_files = labels.get("com.docker.compose.project.config_files")
compose_dir = labels.get("com.docker.compose.project.working_dir")
data_mount = next((m for m in mounts if m.get("destination") == "/data"), {})
onepanel_hint = "1panel" in " ".join(filter(None, [name, compose_dir or "", compose_files or "", data_mount.get("source") or ""])).lower()
if onepanel_hint:
    deployment = "1panel"
elif compose_project:
    deployment = "docker-compose"
else:
    deployment = "docker"

if deployment == "1panel":
    install_notes = [
        "Install Docker and 1Panel using your normal trusted process.",
        "Install Vaultwarden from the 1Panel App Store, preferably using the recorded image version.",
    ]
    secrets_note = "Recreate domain, HTTPS, SMTP and other secrets manually in 1Panel; this manifest intentionally does not contain secret values."
elif deployment == "docker-compose":
    install_notes = [
        "Install Docker and the Compose plugin using your normal trusted process.",
        "Restore your own copy of the compose project (see deployment.compose_config_files) and pin the recorded image version.",
    ]
    secrets_note = "Recreate domain, HTTPS, SMTP and other secrets in your compose file or .env; this manifest intentionally does not contain secret values."
else:
    install_notes = [
        "Install Docker using your normal trusted process.",
        "Recreate the Vaultwarden container with the recorded image, ports, networks, restart policy and /data mount.",
    ]
    secrets_note = "Recreate domain, HTTPS, SMTP and other secrets as container environment variables; this manifest intentionally does not contain secret values."

manifest = {
    "manifest_format": 2,
    "generated_utc": datetime.now(timezone.utc).isoformat(),
    "warning": "Sanitized inventory only. Secret environment-variable values are intentionally omitted. Recreate the deployment manually and review settings before starting it.",
    "deployment": {
        "type": deployment,
        "compose_project": compose_project,
        "compose_config_files": compose_files,
        "compose_working_dir": compose_dir,
        "compose_service": labels.get("com.docker.compose.service"),
    },
    "container": {
        "name": name,
        "image": config.get("Image"),
        "image_reference": config.get("Image"),
        "image_id": obj.get("Image"),
        "restart_policy": (host.get("RestartPolicy") or {}).get("Name"),
        "state": state.get("Status"),
        "health": ((state.get("Health") or {}).get("Status") if state.get("Health") else "no-healthcheck"),
        "ports": ports,
        "networks": networks,
        "mounts": mounts,
        "safe_environment": env_values,
        "omitted_environment_variable_names": sorted(redacted_names),
    },
    "recovery_notes": install_notes + [
        "Stop the newly created Vaultwarden container before restoring its /data mount.",
        "Restore the encrypted /data backup into the new container's host-side /data mount.",
        secrets_note,
    ],
}
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
