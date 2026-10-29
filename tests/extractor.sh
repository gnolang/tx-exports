#!/usr/bin/env bash
# Exercises rules.mk's extractor target on a scratch chain dir:
# - extracted/ is rebuilt from scratch: an earlier tree's leftovers are gone,
#   repeated deploys are numbered (x, x:1), and a second run gives the same tree;
# - a run that fails leaves the previous extracted/ untouched.
# Usage: tests/extractor.sh   (from the repo root; needs GNU make, go, jq)
set -uo pipefail
root=$(cd -- "$(dirname "$0")/.." >/dev/null && pwd) || exit 1
fail=0
ok() { echo "ok   - $1"; }
ko() {
  echo "FAIL - $1"
  fail=1
}
# MAKEFLAGS/MAKELEVEL from a caller would add output or flags to the runs below
mk() { env -u MAKEFLAGS -u MAKELEVEL make -s -C "$@"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp "$root/rules.mk" "$work/" || exit 1
# chain dirs run the extractor from ../extractor
ln -s "$root/extractor" "$work/extractor" || exit 1
mkdir "$work/chain" || exit 1
cat >"$work/chain/Makefile" <<'EOF'
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
-include ../rules.mk
EOF

# a real deploy line, re-pointed at <path> with one file holding <body>
template=$(awk '/"\/vm.m_addpkg"/ {print; exit}' "$root"/test11.gno.land/backup_*.jsonl)
[ -n "$template" ] || exit 1
deploy() {
  jq -c --arg p "$1" --arg b "$2" \
    '.tx.msg = [.tx.msg[] | select(.["@type"] == "/vm.m_addpkg")][0:1]
     | .tx.msg[0].package.path = $p
     | .tx.msg[0].package.files = [{"name": "x.gno", "body": $b}]' <<<"$template"
}
{
  deploy gno.land/r/demo/x first
  deploy gno.land/r/demo/y only
  deploy gno.land/r/demo/x second
} >"$work/chain/backup_0000001-0000010.jsonl" || exit 1
# an earlier tree, with a rerun twin the rebuild must drop
mkdir -p "$work/chain/extracted/r/demo/stale:0" || exit 1

tree() { (cd "$work/chain/extracted" && find . -type f | sort && cat r/demo/x/x.gno r/demo/x:1/x.gno 2>/dev/null); }

if ! out=$(mk "$work/chain" extractor 2>&1); then
  ko "extractor runs: $out"
else
  got=$(cd "$work/chain/extracted/r/demo" && ls | tr '\n' ' ')
  [ "$got" = "x x:1 y " ] && ok "extracted/ is rebuilt with numbered repeated deploys" ||
    ko "extracted/ is rebuilt with numbered repeated deploys: $got"
  [ "$(cat "$work/chain/extracted/r/demo/x/x.gno")" = first ] &&
    [ "$(cat "$work/chain/extracted/r/demo/x:1/x.gno")" = second ] &&
    ok "repeated deploys are numbered in chain order" || ko "repeated deploys are numbered in chain order"
fi
first=$(tree)

mk "$work/chain" extractor >/dev/null 2>&1
[ "$(tree)" = "$first" ] && ok "a second run gives the same tree" || ko "a second run gives the same tree"
[ ! -e "$work/chain/extracted.new" ] && ok "no build dir is left behind" || ko "no build dir is left behind"

mk "$work/chain" extractor EXTRACTOR_DIR=missing >/dev/null 2>&1 && ko "a failing run fails: exited 0" ||
  ok "a failing run fails"
[ "$(tree)" = "$first" ] && ok "a failing run leaves the previous extracted/ untouched" ||
  ko "a failing run leaves the previous extracted/ untouched"
exit $fail
