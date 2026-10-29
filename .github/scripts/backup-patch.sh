#!/usr/bin/env bash
# Carries an exporter run's results from its export job, which builds and runs
# code from outside this repo without a write token, to its commit job, which
# pushes them. The patch holds only the files a run writes in its chain dir:
# its backup_*.jsonl files, metadata.json, README.md and extracted/ tree.
#
#   backup-patch.sh pack <chain dir> <patch>   write those files' changes to <patch>
#   backup-patch.sh apply <chain dir> <patch>  stage <patch> in this checkout, or change
#                                              nothing if it touches any other path or
#                                              writes anything but a regular file
#
# A regular file may be executable: tx-archive writes its backups so, and CI
# commits them as such.
#
# Both run from the repo root.
set -euo pipefail

# allowed <dir> <path>: whether <path> is a file a run writes in <dir>
allowed() {
  local rest=${2#"$1"/}
  [ "$rest" != "$2" ] || return 1
  case $rest in
  extracted/?*) return 0 ;;
  */*) return 1 ;;
  backup_*.jsonl | metadata.json | README.md) return 0 ;;
  *) return 1 ;;
  esac
}

pack() {
  local dir=$1 patch=$2 paths path
  paths=$(mktemp)
  git ls-files -z --modified --deleted --others --exclude-standard -- "$dir" |
    while IFS= read -r -d '' path; do
      if allowed "$dir" "$path"; then printf '%s\0' "$path"; fi
    done | sort -zu >"$paths"
  if [ -s "$paths" ]; then
    git --literal-pathspecs add -A --pathspec-from-file="$paths" --pathspec-file-nul
  fi
  rm -f "$paths"
  git diff --cached --binary --no-renames -- "$dir" >"$patch"
}

apply() {
  local dir=$1 patch=$2 index raw meta path mode refused=0
  # pack always writes the patch: a missing one means the hand-off broke, and an
  # empty one is an idle run
  [ -f "$patch" ] || {
    echo "backup-patch: no patch at $patch" >&2
    return 1
  }
  [ -s "$patch" ] || return 0

  # vet the patch on a throwaway index first: git parses it, and this checkout
  # changes only once every path and mode passes
  index=$(mktemp)
  raw=$(mktemp)
  GIT_INDEX_FILE=$index git read-tree HEAD
  GIT_INDEX_FILE=$index git apply --cached --whitespace=nowarn "$patch"
  # its own command, not a process substitution, whose failure errexit ignores:
  # a vetting that read nothing must not pass
  GIT_INDEX_FILE=$index git diff --cached --raw -z --no-renames HEAD >"$raw"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    mode=$(cut -d' ' -f2 <<<"$meta")
    # 000000 is a deletion; symlinks (120000) and gitlinks (160000) are refused
    if ! allowed "$dir" "$path" || ! [[ $mode =~ ^(100644|100755|000000)$ ]]; then
      # %q keeps a newline in the path from starting a workflow command line
      printf 'backup-patch: refusing %q (mode %s)\n' "$path" "$mode" >&2
      refused=1
    fi
  done <"$raw"
  rm -f "$index" "$raw"
  [ "$refused" = 0 ] || return 1

  git apply --index --whitespace=nowarn "$patch"
}

case ${1-} in
pack | apply) [ $# = 3 ] && "$@" ;;
*)
  echo "usage: backup-patch.sh pack|apply <chain dir> <patch>" >&2
  exit 2
  ;;
esac
