#!/usr/bin/env bash
# Exercises rules.mk's stats target on scratch chain dirs:
# - deployed packages are the /vm.m_addpkg messages only (a /vm.m_run package
#   is not a deploy), whatever the casing of their keys (`path`, or `Path` in
#   test2/test3);
# - realm calls are the /vm.m_call messages only (a package enable or reject
#   carries a pkg_path too);
# - a chain dir narrows the files stats reads (staging's balances file holds
#   `addr=coins` lines, not txs);
# - plain std.Tx lines (test1) are read like {tx, metadata} ones;
# - a corrupt tx line, or a BACKUP_FILES that matches nothing, fails the run.
# Usage: tests/stats.sh   (from the repo root; needs GNU make, bash, jq)
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

# chain <dir> <BACKUP_FILES>: a scratch chain dir with one tx file and a
# balances file
chain() {
  mkdir "$work/$1" || exit 1
  cat >"$work/$1/Makefile" <<EOF
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
BACKUP_FILES = $2
-include ../rules.mk
EOF
  cat >"$work/$1/backup_txs_1-4.jsonl" <<'EOF'
{"tx":{"msg":[{"@type":"/vm.m_addpkg","creator":"g1a","package":{"name":"low","path":"gno.land/r/demo/lowercase","files":[]}}]},"metadata":{"timestamp":"1"}}
{"tx":{"msg":[{"@type":"/vm.m_addpkg","creator":"g1a","package":{"Name":"up","Path":"gno.land/r/demo/capitalized","Files":[]}}]},"metadata":{"timestamp":"2"}}
{"tx":{"msg":[{"@type":"/vm.m_call","caller":"g1a","pkg_path":"gno.land/r/demo/lowercase","func":"Do","args":[]}]},"metadata":{"timestamp":"3"}}
{"tx":{"msg":[{"@type":"/vm.m_run","caller":"g1a","package":{"name":"main","path":"","files":[]}}]},"metadata":{"timestamp":"4"}}
{"tx":{"msg":[{"@type":"/vm.m_enable_pkg","approver":"g1a","pkg_path":"gno.land/p/demo/parked","pkg_hash":"x","pkg_height":"1"}]},"metadata":{"timestamp":"5"}}
{"tx":{"msg":[{"@type":"/vm.m_reject_pkg","sender":"g1a","pkg_path":"gno.land/r/demo/rejected"}]},"metadata":{"timestamp":"6"}}
EOF
  printf 'g1a=1000ugnot\ng1b=2000ugnot\n' >"$work/$1/backup_balances.jsonl"
}

# a README section's lines inside its fence, single-spaced (`uniq -c` pads its
# counts differently in GNU and BSD coreutils)
listing() {
  awk -v h="## $2" '$0 == h {f = 1; next} /^## / {f = 0} f' "$1" |
    awk '!/^```/ && NF {$1 = $1; print}'
}

chain good 'backup_txs_*.jsonl'
if ! out=$(mk "$work/good" stats 2>&1); then
  ko "stats runs: $out"
elif [ -n "$out" ]; then
  ko "stats runs without errors: $out"
else
  ok "stats runs without errors"
fi
readme=$work/good/README.md
got=$(listing "$readme" addpkgs)
want=$(printf '1 "%s"\n' gno.land/r/demo/capitalized gno.land/r/demo/lowercase)
[ "$got" = "$want" ] && ok "addpkgs lists the deploys of both key casings, and no MsgRun" ||
  ko "addpkgs lists the deploys of both key casings, and no MsgRun: $(tr '\n' '|' <<<"$got")"
got=$(listing "$readme" 'top realm calls')
[ "$got" = '1 "gno.land/r/demo/lowercase"' ] && ok "top realm calls lists the calls, and no enable or reject" ||
  ko "top realm calls lists the calls, and no enable or reject: $(tr '\n' '|' <<<"$got")"
got=$(listing "$readme" TXs)
[ "$got" = 6 ] && ok "the tx count covers only the tx files" ||
  ko "the tx count covers only the tx files: $got"

# test1 stores plain std.Tx lines, without the {tx, metadata} wrapper
mkdir "$work/plain" || exit 1
cat >"$work/plain/Makefile" <<'EOF'
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
BACKUP_FILES = txexport-*.log
-include ../rules.mk
EOF
cat >"$work/plain/txexport-aa.log" <<'EOF'
{"msg":[{"@type":"/vm.m_addpkg","creator":"g1a","package":{"Name":"plain","Path":"gno.land/p/demo/plain","Files":[]}}]}
{"msg":[{"@type":"/vm.m_call","caller":"g1a","pkg_path":"gno.land/r/demo/plain","func":"Do","args":[]}]}
EOF
if ! out=$(mk "$work/plain" stats 2>&1); then
  ko "stats runs on plain std.Tx lines: $out"
else
  got=$(listing "$work/plain/README.md" addpkgs)
  [ "$got" = '1 "gno.land/p/demo/plain"' ] && ok "addpkgs lists the deploys of plain std.Tx lines" ||
    ko "addpkgs lists the deploys of plain std.Tx lines: $(tr '\n' '|' <<<"$got")"
  got=$(listing "$work/plain/README.md" 'top realm calls')
  [ "$got" = '1 "gno.land/r/demo/plain"' ] && ok "top realm calls lists the calls of plain std.Tx lines" ||
    ko "top realm calls lists the calls of plain std.Tx lines: $(tr '\n' '|' <<<"$got")"
fi

chain corrupt 'backup_txs_*.jsonl'
echo '{"tx":' >>"$work/corrupt/backup_txs_1-4.jsonl"
mk "$work/corrupt" stats >/dev/null 2>&1 && ko "a corrupt tx line fails stats: exited 0" ||
  ok "a corrupt tx line fails stats"

chain nomatch 'backup_nothing_*.jsonl'
if mk "$work/nomatch" stats >/dev/null 2>&1; then
  ko "a BACKUP_FILES matching nothing fails stats: exited 0"
elif [ -e "$work/nomatch/README.md" ]; then
  ko "a BACKUP_FILES matching nothing fails stats before writing README.md"
else
  ok "a BACKUP_FILES matching nothing fails stats before writing README.md"
fi
exit $fail
