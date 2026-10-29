#!/usr/bin/env bash
# Exercises rules.mk's extractor target on scratch chain dirs:
# - extracted/ is rebuilt from scratch: an earlier tree's leftovers and an
#   interrupted run's build dir are dropped, repeated deploys are numbered
#   (x, x:1), and a second run gives the same tree;
# - a run that fails, or that writes no package, leaves the previous extracted/
#   untouched.
# Usage: tests/extractor.sh   (needs GNU make, go, jq)
set -uo pipefail
root=$(cd -- "$(dirname "$0")/.." >/dev/null && pwd) || exit 1
fail=0
ok() { echo "ok   - $1"; }
ko() {
  echo "FAIL - $1"
  fail=1
}
# MAKEFLAGS, GNUMAKEFLAGS, MAKELEVEL and EXTRACTOR_DIR from a caller would add
# output or flags to the runs below, or point them at another extractor
mk() { env -u MAKEFLAGS -u GNUMAKEFLAGS -u MAKELEVEL -u EXTRACTOR_DIR make -s -C "$@"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp "$root/rules.mk" "$work/" || exit 1
# chain dirs run the extractor from ../extractor
ln -s "$root/extractor" "$work/extractor" || exit 1

# chain <name>: a scratch chain dir whose Makefile includes rules.mk
chain() {
  mkdir "$work/$1" || return 1
  cat >"$work/$1/Makefile" <<'EOF'
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
-include ../rules.mk
EOF
}

# a real deploy line, re-pointed at <path> with one file holding <body>
template=$(awk '/"\/vm.m_addpkg"/ {print; exit}' "$root"/test11.gno.land/backup_*.jsonl)
[ -n "$template" ] || exit 1
deploy() {
  jq -c --arg p "$1" --arg b "$2" \
    '.tx.msg = [.tx.msg[] | select(.["@type"] == "/vm.m_addpkg")][0:1]
     | .tx.msg[0].package.path = $p
     | .tx.msg[0].package.files = [{"name": "x.gno", "body": $b}]' <<<"$template"
}

chain chain || exit 1
{
  deploy gno.land/r/demo/x first
  deploy gno.land/r/demo/y only
  deploy gno.land/r/demo/x second
} >"$work/chain/backup_0000001-0000010.jsonl" || exit 1
# an earlier tree holding a dir no deploy in the backups produces, and an
# interrupted run's partial build dir: the rebuild must drop both
mkdir -p "$work/chain/extracted/r/demo/stale:0" "$work/chain/extracted.new/r/demo/x" || exit 1
: >"$work/chain/extracted.new/r/demo/x/x.gno" || exit 1

if ! out=$(mk "$work/chain" extractor 2>&1); then
  ko "extractor runs: $out"
  exit 1
fi
got=$(cd "$work/chain/extracted/r/demo" && ls | tr '\n' ' ')
if [ "$got" = "x x:1 y " ]; then
  ok "extracted/ is rebuilt with numbered repeated deploys"
else
  ko "extracted/ is rebuilt with numbered repeated deploys: $got"
fi
if [ "$(cat "$work/chain/extracted/r/demo/x/x.gno")" = first ] &&
  [ "$(cat "$work/chain/extracted/r/demo/x:1/x.gno")" = second ]; then
  ok "repeated deploys are numbered in chain order"
else
  ko "repeated deploys are numbered in chain order"
fi
cp -R "$work/chain/extracted" "$work/first" || exit 1

if ! out=$(mk "$work/chain" extractor 2>&1); then
  ko "a second run succeeds: $out"
elif diff -r "$work/first" "$work/chain/extracted" >/dev/null; then
  ok "a second run gives the same tree"
else
  ko "a second run gives the same tree"
fi
if [ ! -e "$work/chain/extracted.new" ]; then
  ok "no build dir is left behind"
else
  ko "no build dir is left behind"
fi

if mk "$work/chain" extractor EXTRACTOR_DIR=missing >/dev/null 2>&1; then
  ko "a failing run fails: exited 0"
else
  ok "a failing run fails"
fi
if diff -r "$work/first" "$work/chain/extracted" >/dev/null; then
  ok "a failing run leaves the previous extracted/ untouched"
else
  ko "a failing run leaves the previous extracted/ untouched"
fi

# backups the extractor parses to no package: an empty build must not replace
# the previous tree
chain nopkg || exit 1
awk '!/"\/vm.m_addpkg"/ {print; exit}' "$root"/test11.gno.land/backup_*.jsonl >"$work/nopkg/backup_0000001-0000010.jsonl" || exit 1
mkdir -p "$work/nopkg/extracted/r/demo/old" || exit 1
echo old >"$work/nopkg/extracted/r/demo/old/x.gno" || exit 1
cp -R "$work/nopkg/extracted" "$work/nopkg-before" || exit 1
if out=$(mk "$work/nopkg" extractor 2>&1); then
  ko "a run that writes no package fails: exited 0"
elif [[ "$out" != *"wrote no package"* ]]; then
  ko "a run that writes no package fails, saying so: $out"
else
  ok "a run that writes no package fails, saying so"
fi
if diff -r "$work/nopkg-before" "$work/nopkg/extracted" >/dev/null 2>&1; then
  ok "a run that writes no package leaves the previous extracted/ untouched"
else
  ko "a run that writes no package leaves the previous extracted/ untouched"
fi
exit $fail
