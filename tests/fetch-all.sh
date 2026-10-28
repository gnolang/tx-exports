#!/usr/bin/env bash
# Exercises rules.mk's fetch-all on scratch chain dirs, without network:
# - it runs one fetch per MAX_INTERVAL chunk and stops at the first that fails
#   (a stub stands in for the per-chunk make);
# - chunks refused by the chain-id guard (the file:// fixture RPC reports
#   another chain) stop it at the first one;
# - an RPC that reports no block height fails it before any fetch.
# Usage: tests/fetch-all.sh   (from the repo root; needs GNU make, curl, jq)
set -uo pipefail
root=$(cd -- "$(dirname "$0")/.." >/dev/null && pwd) || exit 1
fail=0
ok() { echo "ok   - $1"; }
ko() {
  echo "FAIL - $1"
  fail=1
}
# MAKEFLAGS/MAKELEVEL from a caller (e.g. -k) would let a refused fetch build
# its other prerequisites
mk() { env -u MAKEFLAGS -u MAKELEVEL make -s -C "$@"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp "$root/rules.mk" "$work/" || exit 1

# chain <name> <network> <height>: a scratch chain dir and its fixture RPC
# (no height field when <height> is empty)
chain() {
  mkdir -p "$work/$1/chain" "$work/$1/rpc" "$work/$1/x" || exit 1
  # chain dirs include ../rules.mk
  ln -s "$work/rules.mk" "$work/$1/rules.mk" || exit 1
  cat >"$work/$1/chain/Makefile" <<'EOF'
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
CHAIN_ID = example-1
MAX_INTERVAL = 10000
FROM_BLOCK := $(shell cat metadata.json | jq -r '.latest_block_height + 1')
LATEST_BLOCK_HEIGHT := $(shell curl -s $(REMOTE)/status | jq -r '.result.sync_info.latest_block_height')
TO_BLOCK = $(LATEST_BLOCK_HEIGHT)
-include ../rules.mk
EOF
  printf '{\n  "latest_block_height": 0\n}\n' >"$work/$1/chain/metadata.json"
  if [ -n "$3" ]; then
    printf '{"result":{"node_info":{"network":"%s"},"sync_info":{"latest_block_height":"%s"}}}\n' "$2" "$3"
  else
    printf '{"result":{"node_info":{"network":"%s"},"sync_info":{}}}\n' "$2"
  fi >"$work/$1/rpc/status"
  # the stub logs each per-chunk make call, and fails the chunk from 10001
  cat >"$work/$1/x/make" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${0%/*}/chunks.log"
case " $* " in *" FROM_BLOCK=10001 "*) exit 2 ;; esac
EOF
  chmod +x "$work/$1/x/make" || exit 1
}

# three chunks (from 1, 10001, 20001); the second fails
chain stub example-1 25000
mk "$work/stub/chain" fetch-all REMOTE="file://$work/stub/rpc" MAKE="$work/stub/x/make" >/dev/null 2>&1
rc=$?
chunks=$(cat "$work/stub/x/chunks.log" 2>/dev/null)
[ "$rc" -ne 0 ] && ok "fetch-all exits non-zero when a chunk fails" ||
  ko "fetch-all exits non-zero when a chunk fails"
[ "$chunks" = "$(printf -- '-C . fetch FROM_BLOCK=%s\n' 1 10001)" ] &&
  ok "fetch-all fetches chunk by chunk and stops at the first that fails" ||
  ko "fetch-all fetches chunk by chunk and stops at the first that fails: $(tr '\n' '|' <<<"$chunks")"

chain other other-1 25000
out=$(mk "$work/other/chain" fetch-all REMOTE="file://$work/other/rpc" 2>&1)
rc=$?
[ "$rc" -ne 0 ] && [ "$(grep -cF "RPC serves chain 'other-1'" <<<"$out")" -eq 1 ] &&
  ok "a chain refused by the guard stops fetch-all at the first chunk" ||
  ko "a chain refused by the guard stops fetch-all at the first chunk: rc=$rc $(tr '\n' '|' <<<"$out")"

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
exit $fail
