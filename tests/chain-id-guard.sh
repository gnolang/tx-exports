#!/usr/bin/env bash
# Exercises rules.mk's check-chain-id guard for one chain dir without network
# access: the RPC is a file:// fixture whose /status reports the given chain id.
# Usage: tests/chain-id-guard.sh <chain-dir> <its-chain-id>
# Needs GNU make, curl and jq.
set -uo pipefail
dir=${1:?chain dir}
id=${2:?chain id}
fail=0
ok() { echo "ok   - $1"; }
ko() {
  echo "FAIL - $1"
  fail=1
}

rpc=$(mktemp -d)
trap 'rm -rf "$rpc"' EXIT
printf '{"result":{"node_info":{"network":"%s"},"sync_info":{"latest_block_height":"1"}}}\n' "$id" >"$rpc/status"
served="file://$rpc"
# curl fails on it, like on a dead or WAF-blocked RPC
unreadable="file://$rpc/missing"

if out=$(make -s -C "$dir" check-chain-id REMOTE="$served" 2>&1); then
  ok "the declared CHAIN_ID matches the RPC"
else
  ko "the declared CHAIN_ID matches the RPC: $out"
fi

if out=$(make -s -C "$dir" check-chain-id REMOTE="$served" CHAIN_ID="not-$id" 2>&1); then
  ko "another chain id is refused: exited 0"
elif grep -qF -- "'$id'" <<<"$out" && grep -qF -- "'not-$id'" <<<"$out"; then
  ok "another chain id is refused, naming both ids"
else
  ko "another chain id is refused, naming both ids: $out"
fi

if out=$(make -s -C "$dir" check-chain-id REMOTE="$unreadable" CHAIN_ID= 2>&1); then
  ko "an empty CHAIN_ID is refused: exited 0"
elif grep -qF -- "CHAIN_ID is not set" <<<"$out"; then
  ok "an empty CHAIN_ID is refused"
else
  ko "an empty CHAIN_ID is refused: $out"
fi

if out=$(make -s -C "$dir" check-chain-id REMOTE="$unreadable" 2>&1); then
  ko "an unreadable RPC is refused: exited 0"
elif grep -qF -- "curl:" <<<"$out"; then
  ok "an unreadable RPC is refused, with curl's reason"
else
  ko "an unreadable RPC is refused, with curl's reason: $out"
fi

out=$(make -n -C "$dir" fetch REMOTE="$served" 2>&1)
guard_line=$(grep -n 'node_info.network' <<<"$out" | head -1 | cut -d: -f1)
backup_line=$(grep -n 'Backup from' <<<"$out" | head -1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$backup_line" ] && [ "$guard_line" -lt "$backup_line" ]; then
  ok "fetch runs the guard before backing up"
else
  ko "fetch runs the guard before backing up"
fi
exit $fail
