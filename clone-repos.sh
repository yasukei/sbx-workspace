#!/usr/bin/env bash
# Clone GitHub repositories (owner/name format).
# By default, the list is fetched from the authenticated user's repositories
# via `gh api /user/repos`, shown, and confirmed with y/N before cloning.
# Use -f to read the list from a file instead.
# Repositories listed in the exclude file (default: exclude-repos.txt next to
# this script, if present) are left out. Entries are owner/name or just name.
# Repositories whose target directory already exists are not cloned again:
# they are updated with `git fetch --prune`, and additionally with
# `git pull --ff-only` when main is checked out and the working tree is clean
# (no modified, staged or untracked files).
#
# Usage: ./clone-repos.sh [-f repos.txt] [-x exclude.txt] [-y] [destination directory]
#   -f FILE  Read the repository list from FILE instead of `gh api`
#   -x FILE  Read the exclude list from FILE (default: exclude-repos.txt)
#   -y       Skip the confirmation prompt for the `gh api` list
#   Default destination: the script's own directory
set -uo pipefail

usage() {
  echo "Usage: $0 [-f repos.txt] [-x exclude.txt] [-y] [destination directory]" >&2
}

# Strip comments, whitespace, a GitHub URL prefix and a .git suffix,
# then lowercase: "https://github.com/Foo/Bar.git # x" -> "foo/bar"
normalize() {
  local s="${1%%#*}"
  s="$(echo "$s" | xargs)"
  s="${s#https://github.com/}"
  s="${s#git@github.com:}"
  s="${s%.git}"
  echo "${s,,}"
}

# Print the repositories in $1 that are not listed in the exclude file
filter_excluded() {
  local line key ex name
  while IFS= read -r line || [[ -n "$line" ]]; do
    key="$(normalize "$line")"
    [[ -z "$key" ]] && continue
    name="${key##*/}"
    for ex in "${excludes[@]}"; do
      if [[ "$key" == "$ex" || ( "$ex" != */* && "$name" == "$ex" ) ]]; then
        echo "exclude: $line" >&2
        continue 2
      fi
    done
    echo "$line"
  done <<< "$1"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list_file=""
exclude_file=""
assume_yes=0

while getopts ":f:x:yh" opt; do
  case "$opt" in
    f) list_file="$OPTARG" ;;
    x) exclude_file="$OPTARG" ;;
    y) assume_yes=1 ;;
    h) usage; exit 0 ;;
    :) echo "error: -$OPTARG requires an argument" >&2; usage; exit 1 ;;
    \?) echo "error: unknown option -$OPTARG" >&2; usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

dest_dir="${1:-$script_dir}"

excludes=()
if [[ -n "$exclude_file" && ! -f "$exclude_file" ]]; then
  echo "error: $exclude_file not found" >&2
  exit 1
fi
exclude_file="${exclude_file:-$script_dir/exclude-repos.txt}"
if [[ -f "$exclude_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    ex="$(normalize "$line")"
    [[ -n "$ex" ]] && excludes+=("$ex")
  done < "$exclude_file"
fi

if [[ -n "$list_file" ]]; then
  if [[ ! -f "$list_file" ]]; then
    echo "error: $list_file not found" >&2
    exit 1
  fi
  repo_list="$(filter_excluded "$(cat "$list_file")")"
else
  if ! repo_list="$(gh api /user/repos --paginate --jq '.[].full_name')"; then
    echo "error: failed to fetch repository list with gh api" >&2
    exit 1
  fi
  repo_list="$(filter_excluded "$repo_list")"
  if [[ -z "$repo_list" ]]; then
    echo "No repositories found."
    exit 0
  fi

  echo "Repositories to clone into $dest_dir:"
  # shellcheck disable=SC2001  # prefixes every line, not one substitution
  echo "$repo_list" | sed 's/^/  /'
  echo "Total: $(echo "$repo_list" | wc -l)"

  if [[ $assume_yes -eq 0 ]]; then
    if ! { exec 3< /dev/tty; } 2> /dev/null; then
      echo "error: no terminal available for confirmation (use -y to skip)" >&2
      exit 1
    fi
    read -r -u 3 -p "Clone these repositories? [y/N] " answer
    exec 3<&-
    if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      echo "Aborted."
      exit 1
    fi
  fi
fi

cloned=0 updated=0 skipped=0 failed=0

# Update an already-cloned repository: always `git fetch --prune`, and
# fast-forward pull only when main is checked out with a clean working tree
update_existing() {
  local repo="$1" target="$2" branch
  # The target must be the top level of its own work tree; a plain directory
  # inside another repository (e.g. the default destination) does not count
  if [[ ! -d "$target" ]] ||
    [[ "$(git -C "$target" rev-parse --show-toplevel 2> /dev/null)" != "$(cd "$target" && pwd -P)" ]]; then
    echo "skip:  $repo ($target exists but is not a git repository)"
    skipped=$((skipped + 1))
    return
  fi

  echo "fetch: $repo ($target)"
  if ! git -C "$target" fetch --prune < /dev/null; then
    echo "error: failed to fetch $repo" >&2
    failed=$((failed + 1))
    return
  fi

  branch="$(git -C "$target" symbolic-ref --quiet --short HEAD)"
  if [[ "$branch" != "main" ]]; then
    echo "skip:  $repo (not pulled: on '${branch:-detached HEAD}', not main)"
    skipped=$((skipped + 1))
    return
  fi
  if [[ -n "$(git -C "$target" status --porcelain)" ]]; then
    echo "skip:  $repo (not pulled: working tree has changes)"
    skipped=$((skipped + 1))
    return
  fi

  echo "pull:  $repo"
  if git -C "$target" pull --ff-only < /dev/null; then
    updated=$((updated + 1))
  else
    echo "error: failed to pull $repo (not a fast-forward?)" >&2
    failed=$((failed + 1))
  fi
}

while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip comments (after #) and surrounding whitespace; ignore empty lines
  repo="${line%%#*}"
  repo="$(echo "$repo" | xargs)"
  [[ -z "$repo" ]] && continue

  name="${repo##*/}"
  name="${name%.git}"
  target="$dest_dir/$name"

  if [[ -e "$target" ]]; then
    update_existing "$repo" "$target"
    continue
  fi

  # Convert owner/name to a GitHub URL; use full URLs as-is
  if [[ "$repo" == *://* || "$repo" == git@* ]]; then
    url="$repo"
  else
    url="https://github.com/${repo%.git}.git"
  fi

  echo "clone: $repo -> $target"
  if git clone "$url" "$target" < /dev/null; then
    cloned=$((cloned + 1))
  else
    echo "error: failed to clone $repo" >&2
    failed=$((failed + 1))
  fi
done <<< "$repo_list"

echo "Done: cloned=$cloned updated=$updated skipped=$skipped failed=$failed"
[[ $failed -eq 0 ]]
