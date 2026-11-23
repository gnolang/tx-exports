// Package agentpay pays a Mimir agent for one Mimir API call in mUSD: the
// gno.land port of contracts/MimirAgentPay.sol.
//
// The caller asks Mimir for a quote (GET /api/launch/:id/call), which names
// the agent's wallet, the price, a fresh `secret` and
// callId = hex(sha256(secret)). It approves this realm on mUSD and calls Pay
// in the same transaction, then sends the transaction hash and the secret to
// Mimir in `X-Mimir-Payment: gno:<tx>:<secret>`. Mimir reads the Paid event
// and counts it only if its callId is the hash of that secret, so a
// transaction seen on chain is useless to anyone without the secret.
//
// Non-custodial: mUSD moves from the payer straight to the agent in the same
// call; this realm never holds funds, takes no fee and has no owner. The only
// state is the call ids each payer has used, so a quote is paid once. Ids are
// kept per payer, so nobody can spend someone else's pending id first.
package agentpay

import (
	"chain"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/musd"
)

// used: payer + "/" + callId -> true
var used avl.Tree

func Pay(cur realm, agent address, amount int64, callID string) {
	payer := cur.Previous().Address()
	if !agent.IsValid() {
		panic("ZeroAddress")
	}
	if agent == cur.Address() {
		panic("BadAgent")
	}
	if amount <= 0 {
		panic("ZeroAmount")
	}
	if !isHash(callID) {
		panic("BadCallId")
	}
	k := payer.String() + "/" + callID
	if used.Has(k) {
		panic("CallIdUsed")
	}
	used.Set(k, true)
	musd.TransferFrom(cross(cur), payer, agent, amount)
	chain.Emit("Paid", "callId", callID, "agent", agent.String(), "payer", payer.String(),
		"amount", strconv.FormatInt(amount, 10))
}

// Used reports whether payer has already paid for callID.
func Used(payer address, callID string) bool { return used.Has(payer.String() + "/" + callID) }

// isHash accepts a lowercase hex sha256 digest, never the zero hash.
func isHash(s string) bool {
	if len(s) != 64 {
		return false
	}
	zero := true
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
		if c != '0' {
			zero = false
		}
	}
	return !zero
}

func Render(path string) string {
	return "# Mimir agent pay\n\nPays a Mimir agent for one API call in mUSD, straight from the payer to the agent. " +
		"No custody, no fee, no owner. Each call id is paid once per payer.\n"
}
