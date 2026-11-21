#!/usr/bin/env bash
# Tests for clone-repos.sh. Runs fully offline:
# - "remote" repositories are local bare repos reached via file:// URLs
# - `gh` is replaced by a stub on PATH
# - git is limited to the file protocol, so nothing can reach the network
# Also runs shellcheck on clone-repos.sh and on this file.
#
# Usage: tests/test-clone-repos.sh
set -uo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$tests_dir")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Isolate git from the user's configuration and from the network
export HOME="$work/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_TERMINAL_PROMPT=0

# Run a copy of the script so that the real exclude-repos.txt next to it
# is never picked up as the default exclude file
cp "$repo_root/clone-repos.sh" "$work/clone-repos.sh"
script="$work/clone-repos.sh"

passed=0 failed=0 current=""

# --- helpers ---------------------------------------------------------------

begin() {
  current="$1"
  case_dir="$work/case-$((passed + failed + 1))"
  mkdir -p "$case_dir/remotes" "$case_dir/dest"
  echo "--- $current"
}

ok() { echo "  ok:   $1"; passed=$((passed + 1)); }
ng() { echo "  FAIL: $1" >&2; failed=$((failed + 1)); }

# Create a bare "remote" repository with one commit on main
make_remote() {
  local bare="$case_dir/remotes/$1.git" seed="$case_dir/remotes/$1.seed"
  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m "init $1"
  git clone -q --bare "$seed" "$bare"
  git -C "$seed" remote add origin "$bare"
}

# Add a commit to the remote's main
advance_remote() {
  local seed="$case_dir/remotes/$1.seed"
  git -C "$seed" commit -q --allow-empty -m "${2:-update}"
  git -C "$seed" push -q origin main
}

remote_url() { echo "file://$case_dir/remotes/$1.git"; }
remote_head() { git -C "$case_dir/remotes/$1.git" rev-parse main; }

# Run clone-repos.sh; output goes to $out, exit status to $status
run() {
  out="$("$script" "$@" 2>&1 < /dev/null)"
  status=$?
}

assert_status() {
  if [[ $status -eq $1 ]]; then ok "exit status $1"; else ng "exit status: expected $1, got $status"$'\n'"$out"; fi
}

assert_output() {
  if [[ "$out" == *"$1"* ]]; then ok "output contains: $1"; else ng "output lacks: $1"$'\n'"$out"; fi
}

assert_no_output() {
  if [[ "$out" != *"$1"* ]]; then ok "output does not contain: $1"; else ng "output unexpectedly contains: $1"$'\n'"$out"; fi
}

assert_head() {
  local actual
  actual="$(git -C "$1" rev-parse HEAD 2> /dev/null)"
  if [[ "$actual" == "$2" ]]; then ok "$3"; else ng "$3 (HEAD of $1 is ${actual:-none}, expected $2)"; fi
}

assert_exists() { if [[ -e "$1" ]]; then ok "$2"; else ng "$2 ($1 missing)"; fi; }
assert_missing() { if [[ ! -e "$1" ]]; then ok "$2"; else ng "$2 ($1 exists)"; fi; }

# --- shellcheck ------------------------------------------------------------

begin "shellcheck"
if command -v shellcheck > /dev/null; then
  if sc_out="$(shellcheck "$repo_root/clone-repos.sh" "$tests_dir/test-clone-repos.sh" 2>&1)"; then
    ok "no shellcheck findings"
  else
    ng "shellcheck findings:"$'\n'"$sc_out"
  fi
else
  ng "shellcheck is not installed (e.g. apt install shellcheck)"
fi

# --- cloning ---------------------------------------------------------------

begin "clones repositories from a list file"
make_remote alpha
make_remote beta
printf '%s\n' "# comment line" "" "$(remote_url alpha)  # trailing comment" "$(remote_url beta)" > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 0
assert_head "$case_dir/dest/alpha" "$(remote_head alpha)" "alpha cloned"
assert_head "$case_dir/dest/beta" "$(remote_head beta)" "beta cloned"
assert_output "Done: cloned=2 updated=0 skipped=0 failed=0"

begin "clone failure is counted and makes the exit status non-zero"
make_remote alpha
printf '%s\n' "$(remote_url alpha)" "file://$case_dir/remotes/missing.git" > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 1
assert_output "error: failed to clone"
assert_output "Done: cloned=1 updated=0 skipped=0 failed=1"

begin "missing list file is an error"
run -f "$case_dir/nope.txt" "$case_dir/dest"
assert_status 1
assert_output "not found"

# --- updating existing clones ----------------------------------------------

begin "clean main is fetched and pulled"
make_remote alpha
git clone -q "$(remote_url alpha)" "$case_dir/dest/alpha"
advance_remote alpha
remote_url alpha > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 0
assert_head "$case_dir/dest/alpha" "$(remote_head alpha)" "alpha fast-forwarded to remote main"
assert_output "Done: cloned=0 updated=1 skipped=0 failed=0"

begin "fetch --prune removes deleted remote branches"
make_remote alpha
git -C "$case_dir/remotes/alpha.seed" push -q origin main:old-branch
git clone -q "$(remote_url alpha)" "$case_dir/dest/alpha"
git -C "$case_dir/remotes/alpha.git" branch -q -D old-branch
remote_url alpha > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 0
if git -C "$case_dir/dest/alpha" rev-parse -q --verify refs/remotes/origin/old-branch > /dev/null; then
  ng "origin/old-branch was not pruned"
else
  ok "origin/old-branch pruned"
fi

begin "dirty working tree is fetched but not pulled"
make_remote alpha
git clone -q "$(remote_url alpha)" "$case_dir/dest/alpha"
old_head="$(git -C "$case_dir/dest/alpha" rev-parse HEAD)"
advance_remote alpha
touch "$case_dir/dest/alpha/untracked.txt"
remote_url alpha > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 0
assert_head "$case_dir/dest/alpha" "$old_head" "HEAD unchanged"
if [[ "$(git -C "$case_dir/dest/alpha" rev-parse origin/main)" == "$(remote_head alpha)" ]]; then
  ok "origin/main fetched"
else
  ng "origin/main not fetched"
fi
assert_output "not pulled: working tree has changes"
assert_output "Done: cloned=0 updated=0 skipped=1 failed=0"

begin "non-main branch is fetched but not pulled"
make_remote alpha
git clone -q "$(remote_url alpha)" "$case_dir/dest/alpha"
git -C "$case_dir/dest/alpha" checkout -q -b feature
old_head="$(git -C "$case_dir/dest/alpha" rev-parse HEAD)"
advance_remote alpha
remote_url alpha > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 0
assert_head "$case_dir/dest/alpha" "$old_head" "HEAD unchanged"
assert_output "not pulled: on 'feature', not main"

begin "detached HEAD is not pulled"
make_remote alpha
git clone -q "$(remote_url alpha)" "$case_dir/dest/alpha"
git -C "$case_dir/dest/alpha" checkout -q --detach
advance_remote alpha
remote_url alpha > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 0
assert_output "not pulled: on 'detached HEAD', not main"

begin "diverged main fails the pull without merging"
make_remote alpha
git clone -q "$(remote_url alpha)" "$case_dir/dest/alpha"
git -C "$case_dir/dest/alpha" commit -q --allow-empty -m "local"
old_head="$(git -C "$case_dir/dest/alpha" rev-parse HEAD)"
advance_remote alpha
remote_url alpha > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 1
assert_head "$case_dir/dest/alpha" "$old_head" "HEAD unchanged"
assert_output "error: failed to pull"

begin "existing non-git directory is skipped"
make_remote alpha
mkdir "$case_dir/dest/alpha"
remote_url alpha > "$case_dir/list.txt"
run -f "$case_dir/list.txt" "$case_dir/dest"
assert_status 0
assert_output "exists but is not a git repository"
assert_output "Done: cloned=0 updated=0 skipped=1 failed=0"

# --- exclude list ----------------------------------------------------------

begin "exclude list matches owner/name, bare name, case and URL forms"
for n in alpha beta gamma delta; do make_remote "$n"; done
printf '%s\n' "$(remote_url alpha)" "$(remote_url beta)" "$(remote_url gamma)" "$(remote_url delta)" > "$case_dir/list.txt"
# normalize() only strips GitHub URL prefixes, so for file:// entries the
# "owner/name" form is the whole URL without .git
{
  echo "# comment"
  echo "BETA  # bare name, different case"
  echo "file://$case_dir/remotes/gamma"
  echo "file://$case_dir/remotes/delta.git"
} > "$case_dir/exclude.txt"
run -f "$case_dir/list.txt" -x "$case_dir/exclude.txt" "$case_dir/dest"
assert_status 0
assert_exists "$case_dir/dest/alpha" "alpha cloned"
assert_missing "$case_dir/dest/beta" "beta excluded by bare name"
assert_missing "$case_dir/dest/gamma" "gamma excluded by full entry without .git"
assert_missing "$case_dir/dest/delta" "delta excluded by URL with .git"
assert_output "Done: cloned=1 updated=0 skipped=0 failed=0"

begin "GitHub URL forms in the exclude list match owner/name entries"
make_remote alpha
git clone -q "$(remote_url alpha)" "$case_dir/dest/alpha"
printf '%s\n' "Owner/Alpha" "owner/beta" > "$case_dir/list.txt"
printf '%s\n' "https://github.com/owner/alpha.git" "git@github.com:OWNER/beta.git" > "$case_dir/exclude.txt"
run -f "$case_dir/list.txt" -x "$case_dir/exclude.txt" "$case_dir/dest"
assert_status 0
assert_output "exclude: Owner/Alpha"
assert_output "exclude: owner/beta"
assert_no_output "fetch:"

begin "missing exclude file given with -x is an error"
printf '%s\n' "owner/alpha" > "$case_dir/list.txt"
run -f "$case_dir/list.txt" -x "$case_dir/nope.txt" "$case_dir/dest"
assert_status 1
assert_output "not found"

begin "default exclude file next to the script is used"
cp "$script" "$case_dir/clone-repos.sh"
echo "alpha" > "$case_dir/exclude-repos.txt"
make_remote alpha
remote_url alpha > "$case_dir/list.txt"
out="$("$case_dir/clone-repos.sh" -f "$case_dir/list.txt" "$case_dir/dest" 2>&1 < /dev/null)"
status=$?
assert_status 0
assert_missing "$case_dir/dest/alpha" "alpha excluded by default exclude file"

# --- gh api mode (stubbed gh) ----------------------------------------------

# Install a gh stub that prints $GH_STUB_OUTPUT, or fails if GH_STUB_FAIL=1
stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" << 'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_STUB_LOG"
if [[ "${GH_STUB_FAIL:-0}" == 1 ]]; then
  echo "gh stub: failure" >&2
  exit 1
fi
printf '%s\n' "$GH_STUB_OUTPUT"
EOF
chmod +x "$stub_bin/gh"
export PATH="$stub_bin:$PATH"
export GH_STUB_LOG="$work/gh.log"
empty_exclude="$work/empty-exclude.txt"
: > "$empty_exclude"

begin "gh api mode with -y updates repositories listed by gh"
make_remote alpha
git clone -q "$(remote_url alpha)" "$case_dir/dest/alpha"
advance_remote alpha
: > "$GH_STUB_LOG"
echo excluded > "$case_dir/exclude.txt"
GH_STUB_OUTPUT=$'owner/alpha\nowner/excluded' run -y -x "$case_dir/exclude.txt" "$case_dir/dest"
assert_status 0
if grep -q -- "api /user/repos --paginate" "$GH_STUB_LOG"; then ok "gh api /user/repos called"; else ng "gh not called as expected: $(cat "$GH_STUB_LOG")"; fi
assert_output "Repositories to clone into $case_dir/dest:"
assert_output "Total: 1"
assert_output "exclude: owner/excluded"
assert_head "$case_dir/dest/alpha" "$(remote_head alpha)" "alpha pulled"

begin "gh api failure is an error"
GH_STUB_FAIL=1 GH_STUB_OUTPUT="" run -y -x "$empty_exclude" "$case_dir/dest"
assert_status 1
assert_output "failed to fetch repository list"

begin "empty gh result exits successfully"
GH_STUB_OUTPUT="" run -y -x "$empty_exclude" "$case_dir/dest"
assert_status 0
assert_output "No repositories found."

begin "gh api mode without -y and without a terminal refuses to proceed"
# setsid detaches from any controlling terminal, so /dev/tty cannot be opened
out="$(GH_STUB_OUTPUT="owner/alpha" setsid "$script" -x "$empty_exclude" "$case_dir/dest" 2>&1 < /dev/null)"
status=$?
assert_status 1
assert_output "no terminal available"

# --- options ---------------------------------------------------------------

begin "unknown option is an error"
run -z
assert_status 1
assert_output "unknown option -z"

begin "-h prints usage"
run -h
assert_status 0
assert_output "Usage:"

# --- summary ---------------------------------------------------------------

echo
echo "passed=$passed failed=$failed"
[[ $failed -eq 0 ]]
