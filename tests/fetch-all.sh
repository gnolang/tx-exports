#!/usr/bin/env bash
# Exercises rules.mk's fetch-all on a scratch chain dir: it stops at the first
# chunk whose fetch fails, and exits non-zero. Every fetch here is refused by
# the chain-id guard (the file:// fixture RPC reports another chain), so the
# test never reaches tx-archive or the network.
# Usage: tests/fetch-all.sh   (from the repo root; needs GNU make, curl, jq)
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
mkdir "$work/chain" "$work/rpc"
cat >"$work/chain/Makefile" <<'EOF'
REMOTE = "https://rpc.example.invalid"
SHORTNAME = example
CHAIN_ID = example-1
MAX_INTERVAL = 10000
FROM_BLOCK := $(shell cat metadata.json | jq -r '.latest_block_height + 1')
LATEST_BLOCK_HEIGHT := $(shell curl -s $(REMOTE)/status | jq -r '.result.sync_info.latest_block_height')
TO_BLOCK = $(LATEST_BLOCK_HEIGHT)
-include ../rules.mk
EOF
printf '{\n  "latest_block_height": 0\n}\n' >"$work/chain/metadata.json"
# three 10000-block chunks: 1, 10001, 20001
printf '{"result":{"node_info":{"network":"other-1"},"sync_info":{"latest_block_height":"25000"}}}\n' >"$work/rpc/status"

out=$(make -s -C "$work/chain" fetch-all REMOTE="file://$work/rpc" 2>&1)
rc=$?
refusals=$(grep -cF "RPC serves chain 'other-1'" <<<"$out")

[ $rc -ne 0 ] && ok "fetch-all exits non-zero when a chunk fails" || ko "fetch-all exits non-zero when a chunk fails"
[ "$refusals" -eq 1 ] && ok "fetch-all stops at the first failed chunk" ||
  ko "fetch-all stops at the first failed chunk: $refusals chunks attempted"
[ "$(jq .latest_block_height "$work/chain/metadata.json")" = 0 ] &&
  ok "metadata.json is untouched" || ko "metadata.json is untouched"
exit $fail
