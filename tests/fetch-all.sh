#!/usr/bin/env bash
# Exercises rules.mk's fetch-all on scratch chain dirs, without network:
# - it runs one fetch per MAX_INTERVAL chunk and stops at the first that fails
#   (a stub stands in for the per-chunk make);
# - chunks refused by the chain-id guard (the file:// fixture RPC reports
#   another chain) stop it at the first one;
# - it fetches every chunk up to the RPC's height when none fails, and numbers
#   chunks from block 1000000 up in full;
# - a FROM_BLOCK, MAX_INTERVAL or RPC block height that is not a positive number (an
#   unreachable RPC, a missing metadata.json) fails it before any fetch;
# - no fetch gets past the guard (git and go stand-ins would log it).
# Usage: tests/fetch-all.sh   (needs GNU make, curl, jq)
set -uo pipefail
root=$(cd -- "$(dirname "$0")/.." >/dev/null && pwd) || exit 1
fail=0
ok() { echo "ok   - $1"; }
ko() {
  echo "FAIL - $1"
  fail=1
}
# MAKEFLAGS, GNUMAKEFLAGS, MAKELEVEL and MAKEFILES from a caller (e.g. -k) would
# let a refused fetch build its other prerequisites
mk() { env -u MAKEFLAGS -u GNUMAKEFLAGS -u MAKELEVEL -u MAKEFILES make -s -C "$@"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
# rules.mk clones gno under $HOME (mkdir -p runs before git), and curl and jq
# read ~/.curlrc and ~/.jq
export HOME=$work/home
cp "$root/rules.mk" "$work/" || exit 1
# a fetch that gets past the guard clones gno (git) and runs tx-archive (go):
# these stand-ins log the call and fail, so a regression stays offline
mkdir "$work/bin" || exit 1
for t in git go; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/beyond-guard.log"\nexit 1\n' "$t" "$work" >"$work/bin/$t"
  chmod +x "$work/bin/$t" || exit 1
done
PATH=$work/bin:$PATH

# chain <name> <network> <height> [<failing chunk>]: a scratch chain dir and
# its fixture RPC (no height field when <height> is empty)
chain() {
  mkdir -p "$work/$1/chain" "$work/$1/rpc" "$work/$1/x" || exit 1
  # chain dirs include ../rules.mk
  ln -s "$work/rules.mk" "$work/$1/rules.mk" || exit 1
  cat >"$work/$1/chain/Makefile" <<'EOF'
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
CHAIN_ID = example-1
MAX_INTERVAL = 9000
FROM_BLOCK := $(shell cat metadata.json | jq -r '.latest_block_height + 1')
LATEST_BLOCK_HEIGHT := $(shell curl -s $(REMOTE)/status | jq -r '.result.sync_info.latest_block_height')
TO_BLOCK = $(LATEST_BLOCK_HEIGHT)
-include ../rules.mk
EOF
  printf '{\n  "latest_block_height": 4\n}\n' >"$work/$1/chain/metadata.json"
  if [ -n "$3" ]; then
    printf '{"result":{"node_info":{"network":"%s"},"sync_info":{"latest_block_height":"%s"}}}\n' "$2" "$3"
  else
    printf '{"result":{"node_info":{"network":"%s"},"sync_info":{}}}\n' "$2"
  fi >"$work/$1/rpc/status"
  # the stub logs each per-chunk make call, and fails <failing chunk>
  cat >"$work/$1/x/make" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"\${0%/*}/chunks.log"
case " \$* " in *" FROM_BLOCK=${4:-none} "*) exit 2 ;; esac
EOF
  chmod +x "$work/$1/x/make" || exit 1
}

# three chunks (from 5, 9005, 18005); the second fails
chain stub example-1 25000 9005
mk "$work/stub/chain" fetch-all REMOTE="file://$work/stub/rpc" MAKE="$work/stub/x/make" >/dev/null 2>&1
rc=$?
chunks=$(cat "$work/stub/x/chunks.log" 2>/dev/null)
[ "$rc" -ne 0 ] && ok "fetch-all exits non-zero when a chunk fails" ||
  ko "fetch-all exits non-zero when a chunk fails"
[ "$chunks" = "$(printf -- '-C . fetch FROM_BLOCK=%s\n' 5 9005)" ] &&
  ok "fetch-all fetches chunk by chunk and stops at the first that fails" ||
  ko "fetch-all fetches chunk by chunk and stops at the first that fails: $(tr '\n' '|' <<<"$chunks")"

chain other other-1 25000
out=$(mk "$work/other/chain" fetch-all REMOTE="file://$work/other/rpc" 2>&1)
rc=$?
[ "$rc" -ne 0 ] && [ "$(grep -cF "RPC serves chain 'other-1'" <<<"$out")" -eq 1 ] &&
  ok "a chain refused by the guard stops fetch-all at the first chunk" ||
  ko "a chain refused by the guard stops fetch-all at the first chunk: rc=$rc $(tr '\n' '|' <<<"$out")"

chain pass example-1 25000
mk "$work/pass/chain" fetch-all REMOTE="file://$work/pass/rpc" MAKE="$work/pass/x/make" >/dev/null 2>&1
rc=$?
chunks=$(cat "$work/pass/x/chunks.log" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$chunks" = "$(printf -- '-C . fetch FROM_BLOCK=%s\n' 5 9005 18005)" ]; then
  ok "fetch-all fetches every chunk up to the RPC's height"
else
  ko "fetch-all fetches every chunk up to the RPC's height: rc=$rc $(tr '\n' '|' <<<"$chunks")"
fi

# BSD seq prints numbers from 1000000 up in exponent form (1e+06) unless given
# a format, and a fetch from block 1e+06 fails
chain big example-1 1020000
printf '{\n  "latest_block_height": 1000000\n}\n' >"$work/big/chain/metadata.json"
mk "$work/big/chain" fetch-all REMOTE="file://$work/big/rpc" MAX_INTERVAL=10000 MAKE="$work/big/x/make" >/dev/null 2>&1
rc=$?
chunks=$(cat "$work/big/x/chunks.log" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$chunks" = "$(printf -- '-C . fetch FROM_BLOCK=%s\n' 1000001 1010001)" ]; then
  ok "fetch-all numbers chunks from block 1000000 up in full"
else
  ko "fetch-all numbers chunks from block 1000000 up in full: rc=$rc $(tr '\n' '|' <<<"$chunks")"
fi

# curl fails on a missing file:// path, so the height is empty, and
# `seq 1 MAX_INTERVAL` would run one fetch per block (MAX_INTERVAL=3 keeps
# that regression short)
chain unreachable example-1 25000
out=$(mk "$work/unreachable/chain" fetch-all REMOTE="file://$work/unreachable/missing" MAX_INTERVAL=3 MAKE="$work/unreachable/x/make" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ko "an unreachable RPC fails fetch-all: exited 0"
elif [ -e "$work/unreachable/x/chunks.log" ]; then
  ko "an unreachable RPC fails fetch-all before any fetch: $(tr '\n' '|' <"$work/unreachable/x/chunks.log")"
elif ! grep -qF "LATEST_BLOCK_HEIGHT is not a positive number (got '')" <<<"$out"; then
  ko "an unreachable RPC fails fetch-all, naming the empty height: $out"
else
  ok "an unreachable RPC fails fetch-all before any fetch"
fi

chain noheight example-1 ''
out=$(mk "$work/noheight/chain" fetch-all REMOTE="file://$work/noheight/rpc" MAKE="$work/noheight/x/make" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ko "an RPC without a block height fails fetch-all: exited 0"
elif [ -e "$work/noheight/x/chunks.log" ]; then
  ko "an RPC without a block height fails fetch-all before any fetch: $(tr '\n' '|' <"$work/noheight/x/chunks.log")"
else
  ok "an RPC without a block height fails fetch-all before any fetch"
fi
# no metadata.json: FROM_BLOCK is empty, and `seq MAX_INTERVAL HEIGHT` would
# fetch from the wrong block (MAX_INTERVAL=3 keeps that regression short: with
# MAX_INTERVAL above the height, BSD seq counts down, GNU seq prints nothing)
chain nofrom example-1 5
rm "$work/nofrom/chain/metadata.json" || exit 1
out=$(mk "$work/nofrom/chain" fetch-all REMOTE="file://$work/nofrom/rpc" MAX_INTERVAL=3 MAKE="$work/nofrom/x/make" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] || [ -e "$work/nofrom/x/chunks.log" ] || ! grep -qF "FROM_BLOCK is not a positive number (got '')" <<<"$out"; then
  ko "a missing metadata.json fails fetch-all before any fetch, naming FROM_BLOCK: rc=$rc $out"
else
  ok "a missing metadata.json fails fetch-all before any fetch, naming FROM_BLOCK"
fi

# an empty MAX_INTERVAL turns `seq FROM MAX_INTERVAL HEIGHT` into one fetch per block
chain nointerval example-1 5
out=$(mk "$work/nointerval/chain" fetch-all REMOTE="file://$work/nointerval/rpc" MAX_INTERVAL= MAKE="$work/nointerval/x/make" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] || [ -e "$work/nointerval/x/chunks.log" ] || ! grep -qF "MAX_INTERVAL is not a positive number (got '')" <<<"$out"; then
  ko "an empty MAX_INTERVAL fails fetch-all before any fetch: rc=$rc $out"
else
  ok "an empty MAX_INTERVAL fails fetch-all before any fetch"
fi

# a zero MAX_INTERVAL makes seq refuse its step inside the backticks: the loop
# would fetch nothing yet exit 0
chain zero example-1 25000
out=$(mk "$work/zero/chain" fetch-all REMOTE="file://$work/zero/rpc" MAX_INTERVAL=0 MAKE="$work/zero/x/make" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] || [ -e "$work/zero/x/chunks.log" ] || ! grep -qF "MAX_INTERVAL is not a positive number (got '0')" <<<"$out"; then
  ko "a zero MAX_INTERVAL fails fetch-all before any fetch: rc=$rc $out"
else
  ok "a zero MAX_INTERVAL fails fetch-all before any fetch"
fi

# the check shares the loop's recipe line, which names $(MAKE), so make -n runs
# it too instead of dry-running one sub-make per block
chain dryrun example-1 5
out=$(mk "$work/dryrun/chain" -n fetch-all REMOTE="file://$work/dryrun/rpc" MAX_INTERVAL= MAKE="$work/dryrun/x/make" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] || [ -e "$work/dryrun/x/chunks.log" ] || ! grep -qF "MAX_INTERVAL is not a positive number (got '')" <<<"$out"; then
  ko "make -n fetch-all refuses an empty MAX_INTERVAL before any fetch: rc=$rc $out"
else
  ok "make -n fetch-all refuses an empty MAX_INTERVAL before any fetch"
fi

[ ! -e "$work/beyond-guard.log" ] && ok "no fetch got past the guard" ||
  ko "no fetch got past the guard: $(tr '\n' '|' <"$work/beyond-guard.log")"
exit $fail
