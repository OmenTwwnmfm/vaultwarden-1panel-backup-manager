#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/scripts/vw-maintenance.sh"

git init --quiet --initial-branch=main "$TMP/repo"
git -C "$TMP/repo" -c user.name=Tester -c user.email=test@example.invalid commit --quiet --allow-empty -m 'Release fixture'
git -C "$TMP/repo" -c user.name=Tester -c user.email=test@example.invalid tag -a v1.5.0 -m 'Unsigned fixture'
[[ $(git -C "$TMP/repo" cat-file -t v1.5.0) == tag ]]
if verify_release_tag "$TMP/repo" v1.5.0 v1.5.0 "$TMP/signers"; then exit 1; fi
release_version_allowed 1.4.8 1.5.0
if release_version_allowed 1.5.0 1.4.10; then exit 1; fi
if release_version_allowed 1.5.0 1.6.0-dev; then exit 1; fi

ssh-keygen -q -t ed25519 -N "" -f "$TMP/test-key"
printf 'release-test %s\n' "$(cat "$TMP/test-key.pub")" > "$TMP/signers"
git -C "$TMP/repo" -c user.name=Tester -c user.email=test@example.invalid -c gpg.format=ssh -c user.signingkey="$TMP/test-key" tag -s v1.5.1 -m 'Signed fixture'
signed_commit=$(verify_release_tag "$TMP/repo" v1.5.1 v1.5.1 "$TMP/signers")
[[ "$signed_commit" == "$(git -C "$TMP/repo" rev-parse HEAD)" ]]
if verify_release_tag "$TMP/repo" v1.5.1 v9.0.0 "$TMP/signers"; then exit 1; fi

git init --quiet "$TMP/client"
git -C "$TMP/client" fetch --no-tags "$TMP/repo" refs/tags/v1.5.1
[[ "$(verify_release_tag "$TMP/client" FETCH_HEAD v1.5.1 "$TMP/signers")" == "$signed_commit" ]]
echo 'PASS: update policy accepts trusted tags and rejects unsigned, relabeled and downgraded versions'
