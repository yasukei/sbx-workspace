#!/usr/bin/env bash
# Clone GitHub repositories (owner/name format).
# By default, the list is fetched from the authenticated user's repositories
# via `gh api /user/repos`, shown, and confirmed with y/N before cloning.
# Use -f to read the list from a file instead.
# Repositories whose target directory already exists are skipped.
#
# Usage: ./clone-repos.sh [-f repos.txt] [-y] [destination directory]
#   -f FILE  Read the repository list from FILE instead of `gh api`
#   -y       Skip the confirmation prompt for the `gh api` list
#   Default destination: the script's own directory
set -uo pipefail

usage() {
  echo "Usage: $0 [-f repos.txt] [-y] [destination directory]" >&2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list_file=""
assume_yes=0

while getopts ":f:yh" opt; do
  case "$opt" in
    f) list_file="$OPTARG" ;;
    y) assume_yes=1 ;;
    h) usage; exit 0 ;;
    :) echo "error: -$OPTARG requires an argument" >&2; usage; exit 1 ;;
    \?) echo "error: unknown option -$OPTARG" >&2; usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

dest_dir="${1:-$script_dir}"

if [[ -n "$list_file" ]]; then
  if [[ ! -f "$list_file" ]]; then
    echo "error: $list_file not found" >&2
    exit 1
  fi
  repo_list="$(cat "$list_file")"
else
  if ! repo_list="$(gh api /user/repos --paginate --jq '.[].full_name')"; then
    echo "error: failed to fetch repository list with gh api" >&2
    exit 1
  fi
  if [[ -z "$repo_list" ]]; then
    echo "No repositories found."
    exit 0
  fi

  echo "Repositories to clone into $dest_dir:"
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

cloned=0 skipped=0 failed=0

while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip comments (after #) and surrounding whitespace; ignore empty lines
  repo="${line%%#*}"
  repo="$(echo "$repo" | xargs)"
  [[ -z "$repo" ]] && continue

  name="${repo##*/}"
  name="${name%.git}"
  target="$dest_dir/$name"

  if [[ -e "$target" ]]; then
    echo "skip:  $repo ($target already exists)"
    skipped=$((skipped + 1))
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

echo "Done: cloned=$cloned skipped=$skipped failed=$failed"
[[ $failed -eq 0 ]]
