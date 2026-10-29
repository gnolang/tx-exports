#!/usr/bin/env bash
# Exercises rules.mk's extractor target on scratch chain dirs:
# - extracted/ is rebuilt from scratch: an earlier tree's leftovers and an
#   interrupted run's build dir are dropped, repeated deploys are numbered
#   (x, x:1), and a second run gives the same tree;
# - a run that fails, or that writes no package, leaves the previous extracted/
#   untouched;
# - a chain dir's EXTRACTOR_FLAGS reach the extractor;
# - make -j runs join and extractor one at a time.
# Usage: tests/extractor.sh   (needs GNU make, go, jq)
set -uo pipefail
root=$(cd -- "$(dirname "$0")/.." >/dev/null && pwd) || exit 1
fail=0
ok() { echo "ok   - $1"; }
ko() {
  echo "FAIL - $1"
  fail=1
}
# MAKEFLAGS, GNUMAKEFLAGS, MAKELEVEL, EXTRACTOR_DIR and EXTRACTOR_FLAGS from a
# caller would add output or flags to the runs below, or point them at another
# extractor
mk() { env -u MAKEFLAGS -u GNUMAKEFLAGS -u MAKELEVEL -u EXTRACTOR_DIR -u EXTRACTOR_FLAGS make -s -C "$@"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp "$root/rules.mk" "$work/" || exit 1
# chain dirs run the extractor from ../extractor
ln -s "$root/extractor" "$work/extractor" || exit 1

# chain <name> [<make line>]: a scratch chain dir whose Makefile includes
# rules.mk, with <make line> before the include, as in a chain dir, so that
# rules.mk's ?= defaults cannot override it
chain() {
  mkdir "$work/$1" || return 1
  cat >"$work/$1/Makefile" <<EOF
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
${2-}
-include ../rules.mk
EOF
}

# a real deploy line, re-pointed at <path> with one file holding <body>
template=$(awk '/"\/vm.m_addpkg"/ {print; exit}' "$root"/test11.gno.land/backup_*.jsonl)
[ -n "$template" ] || {
  ko "test11 backups hold an m_addpkg line"
  exit 1
}
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
got=$(cd "$work/chain/extracted/r/demo" && printf '%s ' *)
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

# a run that fails after writing a package: w is new, then a deploy the
# extractor cannot parse (a field its gno types do not know) stops it
deploy gno.land/r/demo/w new >"$work/chain/backup_0000011-0000020.jsonl" || exit 1
deploy gno.land/r/demo/v broken | jq -c '.tx.msg[0].package.newfield = 1' \
  >"$work/chain/backup_0000021-0000030.jsonl" || exit 1
if mk "$work/chain" extractor >/dev/null 2>&1; then
  ko "a failing run fails: exited 0"
else
  ok "a failing run fails"
fi
rm -f "$work/chain/backup_0000011-0000020.jsonl" "$work/chain/backup_0000021-0000030.jsonl"
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

# test1's lines predate {tx, metadata} and sit in .log files: its chain dir
# passes two flags, and both must reach the extractor
chain legacy 'EXTRACTOR_FLAGS = -legacy-mode -file-type .log' || exit 1
jq -nc '{msg: [{"@type": "/vm.m_addpkg",
    creator: "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5", deposit: "",
    package: {Name: "old", Path: "gno.land/r/demo/old",
      Files: [{Name: "x.gno", Body: "old"}]}}],
  fee: {gas_wanted: "1", gas_fee: "1ugnot"}, signatures: null, memo: ""}' \
  >"$work/legacy/txexport-aa.log" || exit 1
if ! out=$(mk "$work/legacy" extractor 2>&1); then
  ko "a chain dir's EXTRACTOR_FLAGS reach the extractor: $out"
elif [ "$(cat "$work/legacy/extracted/r/demo/old/x.gno" 2>/dev/null)" = old ]; then
  ok "a chain dir's EXTRACTOR_FLAGS reach the extractor"
else
  ko "a chain dir's EXTRACTOR_FLAGS reach the extractor: $(cd "$work/legacy" && find extracted -type f 2>&1 | tr '\n' ' ')"
fi

# join and extractor read and rewrite the same chain dir, so make -j must run
# them one at a time. Stubs for the stat join calls and the go extractor calls
# mark themselves running, then wait up to 2s for the other to run or finish:
# one that sees the other running records an overlap
chain par || exit 1
deploy gno.land/r/demo/x x >"$work/par/backup_0000001-0000010.jsonl" || exit 1
mkdir "$work/bin" || exit 1
# stub <command> <other command> <what the command then does>
stub() {
  cat >"$work/bin/$1" <<EOF
#!/bin/sh
: >"$work/$1.running"
i=0
while [ ! -e "$work/$2.running" ] && [ ! -e "$work/$2.done" ] && [ \$i -lt 20 ]; do
  sleep 0.1
  i=\$((i + 1))
done
[ -e "$work/$2.running" ] && : >"$work/overlap"
rm "$work/$1.running"
: >"$work/$1.done"
$3
EOF
  chmod +x "$work/bin/$1"
}
stub stat go 'echo 1' || exit 1
stub go stat 'for a; do out=$a; done; mkdir -p "$out/r"' || exit 1
if ! out=$(PATH="$work/bin:$PATH" mk "$work/par" -j2 join extractor 2>&1); then
  ko "make -j runs join and extractor one at a time: $out"
elif [ -e "$work/overlap" ]; then
  ko "make -j runs join and extractor one at a time: they overlapped"
else
  ok "make -j runs join and extractor one at a time"
fi
exit $fail
