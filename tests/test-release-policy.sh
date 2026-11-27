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

# The manager VERSION is the single source; every published reference must match.
version=$(sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$ROOT/scripts/vw-manager.sh")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL: cannot read VERSION from vw-manager.sh" >&2; exit 1; }
check_version_ref() {
  grep -Fq -- "$2" "$ROOT/$1" || { echo "FAIL: $1 does not reference version $version (expected: $2)" >&2; exit 1; }
}
check_version_ref README.md "badge/version-$version-blue"
check_version_ref scripts/README-先阅读.txt "v$version"
check_version_ref docs/完整使用手册.md "**版本 $version**"
check_version_ref docs/完整使用手册.md "**文档版本 $version**"
check_version_ref docs/快速开始.md "**适用版本：$version**"
latest=$(sed -n 's/^## v\([0-9][0-9.]*\) .*/\1/p' "$ROOT/CHANGELOG.md" | head -n 1)
[[ "$latest" == "$version" ]] || { echo "FAIL: latest CHANGELOG entry v$latest does not match VERSION $version" >&2; exit 1; }
echo "PASS: README, docs and CHANGELOG match VERSION $version"
