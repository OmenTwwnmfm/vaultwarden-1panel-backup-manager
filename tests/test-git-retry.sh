#!/usr/bin/env bash
# shellcheck disable=SC2034 # settings are read by the sourced upload_snapshot function
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/backup" "$TMP/tmp"

git init --quiet --bare --initial-branch=main "$TMP/remote.git"
git clone --quiet "$TMP/remote.git" "$TMP/seed"
# git < 2.31 names an empty clone's branch after init.defaultBranch, not the remote HEAD.
git -C "$TMP/seed" symbolic-ref HEAD refs/heads/main
git -C "$TMP/seed" config user.name Tester
git -C "$TMP/seed" config user.email test@example.invalid
printf 'seed\n' > "$TMP/seed/README"
git -C "$TMP/seed" add README
git -C "$TMP/seed" commit --quiet -m 'Initial backup branch'
git -C "$TMP/seed" push --quiet origin main

git clone --quiet "$TMP/remote.git" "$TMP/repo"
git -C "$TMP/repo" config user.name Tester
git -C "$TMP/repo" config user.email test@example.invalid
git clone --quiet "$TMP/remote.git" "$TMP/side"
git -C "$TMP/side" config user.name Tester
git -C "$TMP/side" config user.email test@example.invalid

archive_name=vw-20261127-120000.tar.gz.age
printf 'encrypted archive\n' > "$TMP/backup/$archive_name"
printf 'checksum\n' > "$TMP/backup/$archive_name.sha256"
printf 'signature\n' > "$TMP/backup/$archive_name.sha256.sig"
printf 'manifest\n' > "$TMP/backup/vw-20261127-120000.manifest.json.age"
printf 'manifest checksum\n' > "$TMP/backup/vw-20261127-120000.manifest.json.age.sha256"
printf 'manifest signature\n' > "$TMP/backup/vw-20261127-120000.manifest.json.age.sha256.sig"
printf 'fake deploy key\n' > "$TMP/key"
: > "$TMP/storage.py"

cat > "$TMP/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
[[ "$1" == "$VW_TEST_STORAGE" && "$2" == verify-signature ]] && exit 0
exec "$VW_TEST_REAL_PYTHON" "$@"
PYTHON
cat > "$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
if [[ "$1" == -C && "$3" == push && ! -e "$VW_TEST_INJECTED" ]]; then
  touch "$VW_TEST_INJECTED"
  printf 'remote change\n' > "$VW_TEST_SIDE/remote-change.txt"
  "$VW_TEST_REAL_GIT" -C "$VW_TEST_SIDE" add remote-change.txt
  "$VW_TEST_REAL_GIT" -C "$VW_TEST_SIDE" commit -m 'Concurrent remote change' >/dev/null
  "$VW_TEST_REAL_GIT" -C "$VW_TEST_SIDE" push --quiet origin main
  exec "$VW_TEST_REAL_GIT" "$@"
fi
exec "$VW_TEST_REAL_GIT" "$@"
GIT
chmod +x "$TMP/bin/"*

sed -n '/^upload_snapshot() (/,/^)/p' "$ROOT/scripts/vw-backup.sh" > "$TMP/upload-snapshot.sh"
source "$TMP/upload-snapshot.sh"

VW_TEST_REAL_GIT="$(command -v git)"
VW_TEST_REAL_PYTHON="$(command -v python3)"
VW_TEST_STORAGE="$TMP/storage.py"
VW_TEST_INJECTED="$TMP/push-was-injected"
VW_TEST_SIDE="$TMP/side"
export VW_TEST_REAL_GIT VW_TEST_REAL_PYTHON VW_TEST_STORAGE VW_TEST_INJECTED VW_TEST_SIDE
export PATH="$TMP/bin:$PATH"

STORAGE_TOOL="$VW_TEST_STORAGE"
REPO_DIR="$TMP/repo"
GITHUB_REPO="$(git -C "$REPO_DIR" remote get-url origin)"
GITHUB_BRANCH=main
GITHUB_SSH_KEY="$TMP/key"
GIT_PUSH_RETRIES=3
GIT_RETRY_DELAY=0
MIN_FREE_BYTES=0
MAX_FILE_MIB=90
TMP_ROOT="$TMP/tmp"
BACKUP_DIR="$TMP/backup"
vw_require_free_space() { return 0; }

upload_snapshot github "$BACKUP_DIR/$archive_name"

git -C "$TMP/repo" show-ref --verify --quiet refs/heads/main
history="$(git -C "$TMP/repo" log --oneline --all)"
grep -Fq 'Concurrent remote change' <<<"$history"
git -C "$TMP/remote.git" show refs/heads/main:README >/dev/null
git -C "$TMP/remote.git" show "refs/heads/main:$archive_name" >/dev/null
git -C "$TMP/remote.git" show refs/heads/main:remote-change.txt >/dev/null
echo 'PASS: GitHub push retry refreshes the remote and rebases before retrying'
