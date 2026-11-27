package tributary

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	ptrib "gno.land/p/g196fz02krdlf6fc7a7p2w8e4rkywepwn5c9nh63/tributary"
)

const denom = "ugnot"

var engine = ptrib.NewEngine()

// Register creates a new waterfall node owned by the direct caller.
// If beneficiary is empty, defaults to caller's address.
func Register(cur realm, id, title, pkgRef string, beneficiary address) {
	caller := cur.Previous().Address()
	if beneficiary == "" {
		beneficiary = caller
	}
	if _, err := engine.RegisterNode(id, title, pkgRef, caller, beneficiary, runtime.ChainHeight()); err != nil {
		panic(err.Error())
	}
	chain.Emit("TributaryRegister",
		"id", id,
		"owner", caller.String(),
		"beneficiary", beneficiary.String(),
		"pkgRef", pkgRef,
	)
}

// SetSplits configures upstream dependencies for node id using compact spec syntax:
//
//	"targetA:2000:auth,targetB:1500:ui"
//
// where BPS is 1..10000 (100 = 1.00%) and label is optional.
// Empty spec clears all outgoing splits. Rejects cycles, >10000 BPS, locked nodes, and >8 hops.
func SetSplits(cur realm, id, splitsSpec string) {
	caller := cur.Previous().Address()
	edges, err := parseSplitsSpec(splitsSpec)
	if err != nil {
		panic(err.Error())
	}
	if err := engine.SetSplits(id, caller, edges); err != nil {
		panic(err.Error())
	}
	chain.Emit("TributarySplitsUpdated",
		"id", id,
		"owner", caller.String(),
		"edges", strconv.Itoa(len(edges)),
	)
}

// SetBeneficiary updates the payout address of an unlocked node.
func SetBeneficiary(cur realm, id string, newBeneficiary address) {
	caller := cur.Previous().Address()
	if err := engine.SetBeneficiary(id, caller, newBeneficiary); err != nil {
		panic(err.Error())
	}
	chain.Emit("TributaryBeneficiaryUpdated",
		"id", id,
		"beneficiary", newBeneficiary.String(),
	)
}

// Lock permanently freezes a node's upstream splits and beneficiary so donors
// and downstream realms get an immutable on-chain guarantee against rug-pulls.
func Lock(cur realm, id string) {
	caller := cur.Previous().Address()
	if err := engine.Lock(id, caller); err != nil {
		panic(err.Error())
	}
	chain.Emit("TributaryLocked",
		"id", id,
		"owner", caller.String(),
	)
}

// Deposit routes attached ugnot deterministically through nodeID's entire upstream
// dependency DAG in topological order with zero-dust integer conservation.
// Paired Gno v1.8.0 security guard: requires direct EOA call (IsUserCall) so
// OriginSend is guaranteed to have landed at this realm's escrow address.
func Deposit(cur realm, nodeID, memo string) {
	if !cur.Previous().IsUserCall() {
		panic("tributary: Deposit requires a direct user call (use DepositWithBanker from realms)")
	}
	amt := unsafe.OriginSend().AmountOf(denom)
	if amt <= 0 {
		panic("tributary: attach positive ugnot coins to Deposit")
	}
	caller := cur.Previous().Address()
	rcpt, _, err := engine.Route(nodeID, caller, amt, runtime.ChainHeight(), memo)
	if err != nil {
		panic(err.Error())
	}
	chain.Emit("TributaryDeposit",
		"seq", strconv.FormatInt(rcpt.Seq, 10),
		"entry", nodeID,
		"depositor", caller.String(),
		"amount", strconv.FormatInt(amt, 10),
		"hops", strconv.Itoa(rcpt.Hops),
		"credits", strconv.Itoa(rcpt.Credits),
	)
}

// DepositWithBanker lets another Gno realm forward ugnot programmatically into
// any Tributary DAG using its canonical RealmSend banker (checked via banker.IsCanonical).
func DepositWithBanker(cur realm, nodeID, memo string, senderBanker banker.Banker, amt int64) {
	if !banker.IsCanonical(senderBanker) {
		panic("tributary: non-canonical banker rejected")
	}
	if amt <= 0 {
		panic("tributary: amount must be positive")
	}
	caller := cur.Previous().Address()
	// Pull coins from caller realm into Tributary escrow before crediting ledger.
	senderBanker.SendCoins(caller, cur.Address(), chain.NewCoins(chain.NewCoin(denom, amt)))
	rcpt, _, err := engine.Route(nodeID, caller, amt, runtime.ChainHeight(), memo)
	if err != nil {
		panic(err.Error())
	}
	chain.Emit("TributaryDeposit",
		"seq", strconv.FormatInt(rcpt.Seq, 10),
		"entry", nodeID,
		"depositor", caller.String(),
		"amount", strconv.FormatInt(amt, 10),
		"hops", strconv.Itoa(rcpt.Hops),
		"credits", strconv.Itoa(rcpt.Credits),
	)
}

// Claim withdraws all pending ugnot accrued to the caller across every upstream
// and downstream graph they participate in. Strictly follows Checks-Effects-Interactions.
func Claim(cur realm) int64 {
	caller := cur.Previous().Address()
	return claimFor(cur, caller)
}

// ClaimFor permissionlessly flushes a beneficiary's accrued ugnot directly to
// their own address (useful for keepers or sponsors paying gas for maintainers).
func ClaimFor(cur realm, beneficiary address) int64 {
	return claimFor(cur, beneficiary)
}

func claimFor(cur realm, beneficiary address) int64 {
	// Effects BEFORE interaction (CEI): zero pending balance first.
	amt, err := engine.DeductClaim(beneficiary)
	if err != nil {
		panic(err.Error())
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), beneficiary, chain.NewCoins(chain.NewCoin(denom, amt)))
	chain.Emit("TributaryClaim",
		"beneficiary", beneficiary.String(),
		"amount", strconv.FormatInt(amt, 10),
	)
	return amt
}

// Read-only query helpers for off-chain indexers, RPC clients, and tests.
func PendingBalance(addr address) int64 { return engine.PendingOf(addr) }
func ClaimedBalance(addr address) int64 { return engine.ClaimedOf(addr) }
func TotalRouted() int64                { return engine.TotalRouted() }
func TotalClaimed() int64               { return engine.TotalClaimed() }
func NodeCount() int                    { return engine.NodeCount() }
func LockedCount() int                  { return engine.LockedCount() }

func parseSplitsSpec(spec string) ([]ptrib.Edge, error) {
	trimmed := strings.TrimSpace(spec)
	if trimmed == "" {
		return nil, nil
	}
	parts := strings.Split(trimmed, ",")
	edges := make([]ptrib.Edge, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		fields := strings.Split(part, ":")
		if len(fields) < 2 || len(fields) > 3 {
			return nil, ptrib.ErrInvalidBPS
		}
		bps, err := strconv.ParseInt(strings.TrimSpace(fields[1]), 10, 64)
		if err != nil {
			return nil, ptrib.ErrInvalidBPS
		}
		lbl := ""
		if len(fields) == 3 {
			lbl = strings.TrimSpace(fields[2])
		}
		edges = append(edges, ptrib.Edge{
			TargetID: strings.TrimSpace(fields[0]),
			BPS:      bps,
			Label:    lbl,
		})
	}
	return edges, nil
}
