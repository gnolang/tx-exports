#!/usr/bin/env bash
# Exercises rules.mk's stats target on a scratch chain dir: deployed packages
# are listed whatever the casing of their JSON keys (`path` in current exports,
# `Path` in test2/test3), and a chain dir can narrow the files stats reads so a
# non-tx file (staging's balances) is neither counted nor parsed as a tx.
# Usage: tests/stats.sh   (from the repo root; needs GNU make, jq)
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok() { echo "ok   - $1"; }
ko() {
  echo "FAIL - $1"
  fail=1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$root/rules.mk" "$work/"
mkdir "$work/chain"
cat >"$work/chain/Makefile" <<'EOF'
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
BACKUP_FILES = backup_txs_*.jsonl
-include ../rules.mk
EOF
cat >"$work/chain/backup_txs_1-3.jsonl" <<'EOF'
{"tx":{"msg":[{"@type":"/vm.m_addpkg","creator":"g1a","package":{"name":"low","path":"gno.land/r/demo/lowercase","files":[]}}]},"metadata":{"timestamp":"1"}}
{"tx":{"msg":[{"@type":"/vm.m_addpkg","creator":"g1a","package":{"Name":"up","Path":"gno.land/r/demo/capitalized","Files":[]}}]},"metadata":{"timestamp":"2"}}
{"tx":{"msg":[{"@type":"/vm.m_call","caller":"g1a","pkg_path":"gno.land/r/demo/lowercase","func":"Do","args":[]}]},"metadata":{"timestamp":"3"}}
EOF
printf 'g1a=1000ugnot\ng1b=2000ugnot\n' >"$work/chain/backup_balances.jsonl"

if ! out=$(make -s -C "$work/chain" stats 2>&1); then
  ko "stats runs: $out"
elif [ -n "$out" ]; then
  ko "stats runs without errors: $out"
else
  ok "stats runs without errors"
fi
readme=$(cat "$work/chain/README.md" 2>/dev/null)
section() { awk -v h="## $1" '$0 == h {f = 1; next} /^## / {f = 0} f' <<<"$readme"; }

grep -qF '"gno.land/r/demo/lowercase"' <<<"$(section addpkgs)" &&
  ok "a deploy with a lowercase path is listed" ||
  ko "a deploy with a lowercase path is listed"
grep -qF '"gno.land/r/demo/capitalized"' <<<"$(section addpkgs)" &&
  ok "a deploy with a capitalized Path is listed" ||
  ko "a deploy with a capitalized Path is listed"
grep -qF '"gno.land/r/demo/lowercase"' <<<"$(section 'top realm calls')" &&
  ok "realm calls are listed" ||
  ko "realm calls are listed"
[ "$(section TXs | grep -E '^ *[0-9]+ *$' | tr -d ' ')" = 3 ] &&
  ok "the tx count covers only the tx files" ||
  ko "the tx count covers only the tx files: $(section TXs | tr '\n' ' ')"
exit $fail
