package fund

import "gno.land/p/nt/ufmt/v0"

// ---- screening agent (session key, recommend only) ----

// RecommendWallet posts the agent's screening of a wallet as a salted
// commitment. Nothing about the result is published.
func RecommendWallet(cur realm, wallet address, commitment string) {
	assertAgent(cur)
	checkCommitment(commitment)
	refuseSubAccount(wallet) // review 4, m2
	s := getStatus(wallet)
	if s == nil {
		s = &status{}
		eligibility.Set(wallet.String(), s)
	}
	s.screened = true
}

// RecommendSubscription records that the agent screened a pending direct
// subscription (source of funds). The commitment covers its result.
func RecommendSubscription(cur realm, id int64, commitment string) {
	assertAgent(cur)
	checkCommitment(commitment)
	s := getSub(id)
	if s.status != subPending {
		panic("subscription is not pending")
	}
	s.screened = true
}

// ---- compliance officer (master key, decides) ----

// DecideWallet records a wallet as eligible or not eligible for validDays
// (1 to 365), with a salted commitment to the off-chain file.
func DecideWallet(cur realm, wallet address, eligible bool, validDays int64, commitment string) {
	onlyRole(cur, officer, "compliance officer")
	if !wallet.IsValid() {
		panic("invalid address")
	}
	if isRole(wallet) {
		panic("role holders cannot invest")
	}
	refuseSubAccount(wallet)
	if wallet == fundAddr() || wallet == cashAddr() || wallet == escrowAddr() {
		panic("not an investor address")
	}
	if validDays < 1 || validDays > EligibilityMaxDays {
		panic("validDays must be 1 to 365")
	}
	checkCommitment(commitment)
	s := getStatus(wallet)
	if s == nil {
		s = &status{}
		eligibility.Set(wallet.String(), s)
	}
	countScreening(s.screened)
	s.eligible = eligible
	s.expiresAt = now() + validDays*86400
	s.commitment = commitment
	s.decidedAt = heightNow()
	s.screened = false
	word := "eligible"
	if !eligible {
		word = "not eligible"
	}
	// The trail names no wallet (design review 1, B5).
	addTrail("compliance", ufmt.Sprintf("A wallet was found %s, for %d days.", word, validDays))
}

// DecideSubscription approves or rejects a pending direct subscription while
// the period is open. A rejection refunds in the same transaction, except
// for a restricted wallet, whose subscription is held instead.
func DecideSubscription(cur realm, id int64, approve bool, commitment string) {
	onlyRole(cur, officer, "compliance officer")
	requireState(stateOpen)
	checkCommitment(commitment)
	s := getSub(id)
	if s.status != subPending {
		panic("subscription is not pending")
	}
	if approve {
		if !isEligible(s.wallet) {
			panic("wallet is not eligible, or its eligibility has expired")
		}
		countScreening(s.screened)
		s.status = subApproved
		s.screened = false
		approvedEscrow += s.amount
		addTrail("compliance", ufmt.Sprintf("Subscription #%d approved.", id))
		return
	}
	if held(s.wallet, s.payee) {
		panic("wallet is restricted; the subscription is held")
	}
	countScreening(s.screened)
	closeSub(cur, s, true)
}

// Restrict blocks a wallet: its pending orders are held, not dealt or
// refunded, until the restriction is lifted. Shown only as "restricted".
func Restrict(cur realm, wallet address, commitment string) {
	onlyRole(cur, officer, "compliance officer")
	checkCommitment(commitment)
	refuseSubAccount(wallet)
	s := getStatus(wallet)
	if s == nil {
		s = &status{}
		eligibility.Set(wallet.String(), s)
	}
	if s.restricted {
		panic("already restricted")
	}
	s.restricted = true
	s.commitment = commitment
	s.decidedAt = heightNow()
	addTrail("compliance", "A wallet was restricted.")
}

// Lift removes a restriction.
func Lift(cur realm, wallet address, commitment string) {
	onlyRole(cur, officer, "compliance officer")
	checkCommitment(commitment)
	s := getStatus(wallet)
	if s == nil || !s.restricted {
		panic("not restricted")
	}
	s.restricted = false
	s.commitment = commitment
	s.decidedAt = heightNow()
	addTrail("compliance", "A restriction was lifted.")
}

// refuseSubAccount keeps compliance outcomes about nominee sub-accounts off
// the chain: the nominee handles them (review 2, I4).
func refuseSubAccount(a address) {
	if isSubAccount(a) {
		panic("nominee sub-accounts are handled by the nominee, off-chain")
	}
}

func countScreening(screened bool) {
	if screened {
		decisionsScreened++
	} else {
		decisionsUnscreened++
	}
}

// WalletStatus tells a wallet where it stands: eligible or not, until when
// (unix seconds), and whether it is restricted. Nothing else is kept on-chain.
func WalletStatus(wallet address) (eligible bool, expiresAt int64, restricted bool) {
	s := getStatus(wallet)
	if s == nil {
		return false, 0, false
	}
	return s.eligible && now() < s.expiresAt, s.expiresAt, s.restricted
}

// Holding returns a wallet's shares and their value at the last approved
// NAV per share.
func Holding(wallet address) (shares, value int64) {
	h := getHolder(wallet)
	if h == nil || h.shares == 0 {
		return 0, 0
	}
	return h.shares, valueOfShares(h.shares)
}
