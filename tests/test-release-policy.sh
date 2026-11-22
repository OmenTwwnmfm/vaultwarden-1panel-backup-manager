#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/scripts/vw-maintenance.sh"

git init --quiet --initial-branch=main "$TMP/repo"
git -C "$TMP/repo" config user.name Tester
git -C "$TMP/repo" config user.email test@example.invalid
mkdir "$TMP/repo/scripts"
printf '%s\n' 'VERSION="1.5.0"' > "$TMP/repo/scripts/vw-manager.sh"
printf '%s\n' '# Changelog' > "$TMP/repo/CHANGELOG.md"
printf '%s\n' 'printf "Restarted manager\n"' > "$TMP/repo/run.sh"
git -C "$TMP/repo" add -- scripts/vw-manager.sh CHANGELOG.md run.sh
git -C "$TMP/repo" commit --quiet -m 'Initial version'
git clone --quiet "$TMP/repo" "$TMP/client"
initial_commit=$(git -C "$TMP/client" rev-parse HEAD)
git -C "$TMP/repo" commit --quiet --allow-empty -m 'Update v1.5.0 on main'
updated_commit=$(git -C "$TMP/repo" rev-parse HEAD)

info() { printf '%s\n' "$*"; }
ok() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
install_helper_scripts() { printf '%s\n' 'Synced helpers'; }

export VBM_PROJECT_ROOT="$TMP/client" UPDATE_CHANNEL=stable
VERSION=1.5.0
(check_for_project_updates) <<< no > "$TMP/declined"
[[ "$(git -C "$TMP/client" rev-parse HEAD)" == "$initial_commit" ]]
(check_for_project_updates) <<< yes > "$TMP/updated"
[[ "$(git -C "$TMP/client" rev-parse HEAD)" == "$updated_commit" ]]
[[ -z "$(git -C "$TMP/client" tag --list)" ]]
grep -Fxq 'Synced helpers' "$TMP/updated"
grep -Fxq 'Restarted manager' "$TMP/updated"

printf '%s\n' 'VERSION="1.4.10"' > "$TMP/repo/scripts/vw-manager.sh"
git -C "$TMP/repo" commit --quiet -am 'Lower version on main'
if (check_for_project_updates) <<< yes; then exit 1; fi
[[ "$(git -C "$TMP/client" rev-parse HEAD)" == "$updated_commit" ]]

release_version_allowed 1.4.8 1.5.0
if release_version_allowed 1.5.0 1.4.10; then exit 1; fi
if release_version_allowed 1.5.0 1.6.0-dev; then exit 1; fi
echo 'PASS: updater follows main with confirmation, ignores legacy channel settings, and rejects downgrades'
