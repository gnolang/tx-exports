package fee_split

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	owner    = testutils.TestAddress("owner")
	alice    = testutils.TestAddress("alice")
	bob      = testutils.TestAddress("bob")
	carol    = testutils.TestAddress("carol")
	dave     = testutils.TestAddress("dave")
	attacker = testutils.TestAddress("attacker")
)

// resetState resets all package-level state between tests.
// Required because Gno test functions share the same VM context.
func resetState() {
	splits = make(map[string]*Split)
	splitIDs = []string{}
	ownerSplits = make(map[address]int)
	nextID = 1
	feeBps = 0
	feeAdmin = feeAdminAddr
	pendingFeeAdmin = ""
	feesAccrued = 0
	feesClaimed = 0
}

var feeAdminAddr = testutils.TestAddress("feeadmin")

func addrList(addrs ...address) string {
	parts := make([]string, len(addrs))
	for i, a := range addrs {
		parts[i] = string(a)
	}
	return strings.Join(parts, ",")
}

// fund gives the realm's package address coins so Claim payouts succeed,
// mirroring the deposits the accounting records.
func fund(amount int64) {
	pkgAddr := chain.PackageAddress("gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/fee_split/v2")
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: Denom, Amount: amount}})
}

// deposit performs a coin-backed deposit as addr.
func deposit(cur realm, addr address, splitID string, amount int64) {
	testing.SetRealm(testing.NewUserRealm(addr))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: amount}})
	fund(amount)
	Deposit(cross(cur), splitID)
	testing.SetOriginSend(nil)
}

// ---------- CreateSplit ----------

func TestCreateSplit_Basic(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	id := CreateSplit(cross(cur), addrList(alice, bob), "6000,4000")
	uassert.Equal(t, "split_1", id)

	s := splits["split_1"]
	uassert.Equal(t, string(owner), string(s.Owner))
	uassert.Equal(t, 2, len(s.Recipients))
	uassert.Equal(t, string(alice), string(s.Recipients[0]))
	uassert.Equal(t, string(bob), string(s.Recipients[1]))
	uassert.Equal(t, int64(6000), s.Shares[0])
	uassert.Equal(t, int64(4000), s.Shares[1])
	uassert.False(t, s.Frozen, "new split must not be frozen")
	uassert.Equal(t, int64(0), s.TotalDeposited)
	uassert.Equal(t, int64(0), s.TotalClaimed)
}

func TestCreateSplit_IDsIncrement(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	id1 := CreateSplit(cross(cur), addrList(alice), "10000")
	id2 := CreateSplit(cross(cur), addrList(bob), "10000")
	uassert.Equal(t, "split_1", id1)
	uassert.Equal(t, "split_2", id2)
}

func TestCreateSplit_DuplicateRecipient(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur,
		"duplicate recipient: "+string(alice),
		func() { CreateSplit(cross(cur), addrList(alice, alice), "5000,5000") },
	)
}

func TestCreateSplit_SharesDontSum(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur,
		"shares must sum to 10000 basis points, got 5000",
		func() { CreateSplit(cross(cur), addrList(alice), "5000") },
	)
}

func TestCreateSplit_LengthMismatch(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur,
		"recipients and shares must have the same length",
		func() { CreateSplit(cross(cur), addrList(alice, bob), "10000") },
	)
}

func TestCreateSplit_InvalidAddressRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur,
		"invalid recipient address: not_an_address",
		func() { CreateSplit(cross(cur), "not_an_address", "10000") },
	)
}

func TestCreateSplit_PerOwnerLimit(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	for i := 0; i < MaxSplitsPerOwner; i++ {
		CreateSplit(cross(cur), addrList(alice), "10000")
	}
	uassert.AbortsWithMessage(t, cur,
		"per-owner split limit reached",
		func() { CreateSplit(cross(cur), addrList(alice), "10000") },
	)
}

// ---------- Deposit (coin-backed) ----------

func TestDeposit_UsesSentCoins(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")

	deposit(cur, owner, id, 1000)

	s := splits[id]
	uassert.Equal(t, int64(1000), s.TotalDeposited)
	uassert.Equal(t, int64(500), s.Balances[alice])
	uassert.Equal(t, int64(500), s.Balances[bob])
}

func TestDeposit_NoCoinsPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	// no SetOriginSend: nothing attached to the call
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur,
		"deposit must send exactly one coin of "+Denom,
		func() { Deposit(cross(cur), id) },
	)
	uassert.Equal(t, int64(0), splits[id].TotalDeposited)
}

func TestDeposit_WrongDenomPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	testing.SetOriginSend(chain.Coins{{Denom: "ufoo", Amount: 100}})
	uassert.AbortsWithMessage(t, cur,
		"deposit must send exactly one coin of "+Denom,
		func() { Deposit(cross(cur), id) },
	)
	testing.SetOriginSend(nil)
}

func TestDeposit_RoundingDustGoesToHighestShare(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob, carol), "3334,3333,3333")

	deposit(cur, owner, id, 10)

	s := splits[id]
	uassert.Equal(t, int64(10), s.TotalDeposited)
	// alice: (10*3334)/10000 = 3, +1 dust (highest share)
	uassert.Equal(t, int64(4), s.Balances[alice])
	uassert.Equal(t, int64(3), s.Balances[bob])
	uassert.Equal(t, int64(3), s.Balances[carol])
}

func TestDeposit_AccumulatesAcrossMultipleDeposits(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")

	deposit(cur, owner, id, 100)
	deposit(cur, owner, id, 200)

	s := splits[id]
	uassert.Equal(t, int64(300), s.TotalDeposited)
	uassert.Equal(t, int64(150), s.Balances[alice])
	uassert.Equal(t, int64(150), s.Balances[bob])
}

func TestDeposit_OverflowGuard(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: MaxDepositAmount + 1}})
	uassert.AbortsWithMessage(t, cur,
		"deposit exceeds maximum supported amount",
		func() { Deposit(cross(cur), id) },
	)
	testing.SetOriginSend(nil)
	uassert.Equal(t, int64(0), splits[id].TotalDeposited)
}

func TestDeposit_FrozenSplitPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	Freeze(cross(cur), id)

	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 100}})
	uassert.AbortsWithMessage(t, cur,
		"split is frozen",
		func() { Deposit(cross(cur), id) },
	)
	testing.SetOriginSend(nil)
}

func TestDeposit_UnknownSplitPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, cur,
		"split not found: split_99",
		func() { Deposit(cross(cur), "split_99") },
	)
}

// ---------- Claim (pays out coins) ----------

func TestClaim_SendsCoins(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "7000,3000")
	deposit(cur, owner, id, 10000)

	before := banker.NewReadonlyBanker().GetCoins(alice).AmountOf(Denom)

	testing.SetRealm(testing.NewUserRealm(alice))
	claimed := Claim(cross(cur), id)
	uassert.Equal(t, int64(7000), claimed)

	after := banker.NewReadonlyBanker().GetCoins(alice).AmountOf(Denom)
	uassert.Equal(t, int64(7000), after-before)

	s := splits[id]
	uassert.Equal(t, int64(0), s.Balances[alice])
	uassert.Equal(t, int64(7000), s.TotalClaimed)
}

func TestClaim_CallerIdentityIsEnforced(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 100)

	// the attacker cannot claim alice's balance: identity comes from the
	// chain, not from an argument
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"not a recipient of this split",
		func() { Claim(cross(cur), id) },
	)
	uassert.Equal(t, int64(100), splits[id].Balances[alice])
}

func TestClaim_NothingToClaim(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur,
		"nothing to claim",
		func() { Claim(cross(cur), id) },
	)
}

func TestClaim_CannotClaimTwice(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 100)

	testing.SetRealm(testing.NewUserRealm(alice))
	Claim(cross(cur), id)
	uassert.AbortsWithMessage(t, cur,
		"nothing to claim",
		func() { Claim(cross(cur), id) },
	)
}

func TestClaim_ExRecipientKeepsAccruedBalance(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")
	deposit(cur, owner, id, 1000)

	testing.SetRealm(testing.NewUserRealm(owner))
	UpdateShares(cross(cur), id, addrList(carol, dave), "6000,4000")

	// bob was removed but keeps — and can claim — his accrued 500
	testing.SetRealm(testing.NewUserRealm(bob))
	claimed := Claim(cross(cur), id)
	uassert.Equal(t, int64(500), claimed)
}

// ---------- UpdateShares ----------

func TestUpdateShares_Basic(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")

	UpdateShares(cross(cur), id, addrList(alice, carol), "7000,3000")

	s := splits[id]
	uassert.Equal(t, 2, len(s.Recipients))
	uassert.Equal(t, string(alice), string(s.Recipients[0]))
	uassert.Equal(t, string(carol), string(s.Recipients[1]))
	uassert.Equal(t, int64(7000), s.Shares[0])
	uassert.Equal(t, int64(3000), s.Shares[1])
}

func TestUpdateShares_PreservesUnclaimedBalances(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")
	deposit(cur, owner, id, 1000)

	testing.SetRealm(testing.NewUserRealm(owner))
	UpdateShares(cross(cur), id, addrList(carol, dave), "6000,4000")

	s := splits[id]
	uassert.Equal(t, int64(500), s.Balances[alice])
	uassert.Equal(t, int64(500), s.Balances[bob])
}

func TestUpdateShares_WrongOwner(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the owner can update shares",
		func() { UpdateShares(cross(cur), id, addrList(alice), "10000") },
	)
}

func TestUpdateShares_FrozenSplitPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	Freeze(cross(cur), id)

	uassert.AbortsWithMessage(t, cur,
		"split is frozen",
		func() { UpdateShares(cross(cur), id, addrList(alice, bob), "5000,5000") },
	)
}

// ---------- TransferOwnership / AcceptOwnership (two-step, v2 Y1) ----------

func TestTransferOwnership_TwoStep(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	TransferOwnership(cross(cur), id, bob)
	// staging moves NOTHING: owner, both quotas unchanged
	uassert.Equal(t, string(owner), string(splits[id].Owner))
	uassert.Equal(t, string(bob), string(splits[id].PendingOwner))
	uassert.Equal(t, 1, ownerSplits[owner])
	uassert.Equal(t, 0, ownerSplits[bob])

	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptOwnership(cross(cur), id)
	uassert.Equal(t, string(bob), string(splits[id].Owner))
	uassert.Equal(t, "", string(splits[id].PendingOwner))
}

func TestTransferOwnership_WrongOwner(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the owner can transfer ownership",
		func() { TransferOwnership(cross(cur), id, attacker) },
	)
}

func TestAcceptOwnership_OnlyNominee(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	TransferOwnership(cross(cur), id, bob)

	// a non-nominee cannot accept — including with no nomination staged
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"caller is not the pending owner",
		func() { AcceptOwnership(cross(cur), id) },
	)
	// the owner clears the nomination; the ex-nominee can no longer accept
	testing.SetRealm(testing.NewUserRealm(owner))
	TransferOwnership(cross(cur), id, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur,
		"caller is not the pending owner",
		func() { AcceptOwnership(cross(cur), id) },
	)
}

func TestAcceptOwnership_MovesOwnerSlotAtConsent(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	uassert.Equal(t, 1, ownerSplits[owner])
	TransferOwnership(cross(cur), id, bob)

	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptOwnership(cross(cur), id)

	// the creator's slot is freed; the acceptor's is consumed
	uassert.Equal(t, 0, ownerSplits[owner])
	uassert.Equal(t, 1, ownerSplits[bob])

	// and the creator can fill the freed slot again
	testing.SetRealm(testing.NewUserRealm(owner))
	for i := 0; i < MaxSplitsPerOwner; i++ {
		CreateSplit(cross(cur), addrList(alice), "10000")
	}
}

func TestAcceptOwnership_AcceptorAtLimitBlocked(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(bob))
	for i := 0; i < MaxSplitsPerOwner; i++ {
		CreateSplit(cross(cur), addrList(alice), "10000")
	}

	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	TransferOwnership(cross(cur), id, bob)

	// the quota gate fires at ACCEPT, against the acceptor's own count
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur,
		"new owner is at the per-owner split limit",
		func() { AcceptOwnership(cross(cur), id) },
	)
}

// The v2 audit Y1 griefing scenario is dead: staging a transfer at a
// victim consumes none of the victim's quota and changes nothing the
// victim must act on.
func TestTransferOwnership_UnconsentedGriefDefused(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(attacker))
	for i := 0; i < MaxSplitsPerOwner; i++ {
		id := CreateSplit(cross(cur), addrList(alice), "10000")
		TransferOwnership(cross(cur), id, bob) // staged at the victim, never accepted
	}
	// victim quota untouched; victim can still create a full quota of splits
	uassert.Equal(t, 0, ownerSplits[bob])
	testing.SetRealm(testing.NewUserRealm(bob))
	for i := 0; i < MaxSplitsPerOwner; i++ {
		CreateSplit(cross(cur), addrList(alice), "10000")
	}
	// while the attacker's own budget stays consumed — as documented
	uassert.Equal(t, MaxSplitsPerOwner, ownerSplits[attacker])
}

// Self-transfer is refused at STAGE time. This guard is what makes
// self-accept unreachable, and so what keeps AcceptOwnership's -1/+1
// quota pair from collapsing onto one address (v2 audit G-7.1).
func TestTransferOwnership_SelfRefused(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	uassert.AbortsWithMessage(t, cur,
		"new owner is already the owner",
		func() { TransferOwnership(cross(cur), id, owner) },
	)
	uassert.Equal(t, 1, ownerSplits[owner])
}

// Re-staging overwrites the prior nomination; only the latest nominee
// can accept (v2 audit G-7.4).
func TestTransferOwnership_RestageOverwrites(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	TransferOwnership(cross(cur), id, bob)
	TransferOwnership(cross(cur), id, alice)
	uassert.Equal(t, string(alice), GetPendingOwner(id))

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur,
		"caller is not the pending owner",
		func() { AcceptOwnership(cross(cur), id) },
	)
	testing.SetRealm(testing.NewUserRealm(alice))
	AcceptOwnership(cross(cur), id)
	uassert.Equal(t, string(alice), string(splits[id].Owner))
}

// A nomination on a split that is later archived is inert — the doc
// comment on AcceptOwnership claims it, this pins it (v2 audit G-7.2).
func TestAcceptOwnership_ArchivedRefused(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	TransferOwnership(cross(cur), id, bob)
	Archive(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "split is archived: "+id,
		func() { AcceptOwnership(cross(cur), id) },
	)
	// the archived split's slot stays returned to its creator, not the nominee
	uassert.Equal(t, 0, ownerSplits[owner])
	uassert.Equal(t, 0, ownerSplits[bob])
}

// Freezing locks shares and deposits, not custody: a frozen split stays
// transferable so its owner can hand off claim-servicing duty
// (v2 audit G-7.3).
func TestAcceptOwnership_FrozenAllowed(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	TransferOwnership(cross(cur), id, bob)
	Freeze(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptOwnership(cross(cur), id)
	uassert.Equal(t, string(bob), string(splits[id].Owner))
	uassert.True(t, splits[id].Frozen)
}

// The nominee can read the offer without paying gas to probe it, and the
// pending line disappears once consumed or cleared (v2 audit Y1-obs).
func TestPendingOwner_ReadSurface(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	uassert.Equal(t, "", GetPendingOwner(id))
	uassert.False(t, strings.Contains(GetSplitInfo(id), "Pending owner:"))

	TransferOwnership(cross(cur), id, bob)
	uassert.Equal(t, string(bob), GetPendingOwner(id))
	uassert.True(t, strings.Contains(GetSplitInfo(id), "Pending owner: "+string(bob)))
	uassert.True(t, strings.Contains(Render(""), "Pending owner: "+string(bob)))

	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptOwnership(cross(cur), id)
	uassert.Equal(t, "", GetPendingOwner(id))
	uassert.False(t, strings.Contains(GetSplitInfo(id), "Pending owner:"))
}

// ---------- Freeze ----------

func TestFreeze_Basic(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	Freeze(cross(cur), id)
	uassert.True(t, splits[id].Frozen, "split must be frozen after Freeze()")
}

func TestFreeze_WrongOwner(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur,
		"only the owner can freeze",
		func() { Freeze(cross(cur), id) },
	)
}

func TestFreeze_ClaimsStillWork(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 100)

	testing.SetRealm(testing.NewUserRealm(owner))
	Freeze(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(100), Claim(cross(cur), id))
}

// ---------- Archive ----------

func TestArchive_BlocksWithOutstandingBalance(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 100)

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur,
		"cannot archive: outstanding balance for "+string(alice),
		func() { Archive(cross(cur), id) },
	)
}

func TestArchive_BlocksOnExRecipientBalance(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")
	deposit(cur, owner, id, 1000)

	testing.SetRealm(testing.NewUserRealm(owner))
	// remove bob; his 500 stays claimable
	UpdateShares(cross(cur), id, addrList(alice), "10000")
	testing.SetRealm(testing.NewUserRealm(alice))
	Claim(cross(cur), id)

	// archive must refuse while the EX-recipient still has a balance —
	// archiving would lock his claim forever
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur,
		"cannot archive: outstanding balance for "+string(bob),
		func() { Archive(cross(cur), id) },
	)

	// once bob claims, archive succeeds
	testing.SetRealm(testing.NewUserRealm(bob))
	Claim(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(owner))
	Archive(cross(cur), id)
	uassert.True(t, splits[id].Archived, "split must be archived")
}

// ---------- queries ----------

func TestGetClaimable(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "8000,2000")
	deposit(cur, owner, id, 5000)

	uassert.Equal(t, int64(4000), GetClaimable(id, alice))
	uassert.Equal(t, int64(1000), GetClaimable(id, bob))
	uassert.Equal(t, int64(0), GetClaimable(id, attacker))
}

func TestGetSplitInfo_ContainsExpectedFields(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")
	deposit(cur, owner, id, 200)

	info := GetSplitInfo(id)
	uassert.True(t, strings.Contains(info, "Owner"), "GetSplitInfo output must contain 'Owner'")
	uassert.True(t, strings.Contains(info, string(owner)), "GetSplitInfo output must contain owner address")
	uassert.True(t, strings.Contains(info, string(alice)), "GetSplitInfo output must contain recipient")
}

// ---------- render ----------

func TestRender_EmptyState(cur realm, t *testing.T) {
	resetState()

	out := Render("")
	uassert.Equal(t, "# Fee Split\n\nNo active splits.\n", out)
}

func TestRender_WithSplits(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	CreateSplit(cross(cur), addrList(alice, bob), "6000,4000")
	deposit(cur, owner, "split_1", 1000)

	out := Render("")
	uassert.True(t, strings.Contains(out, "split_1"), "Render output must reference split_1")
	uassert.True(t, strings.Contains(out, string(owner)), "Render output must include owner")
}

// ---------- re-audit regressions (2026-09-02) ----------

func TestCreateSplit_ShareSumWraparoundRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	// re-audit P1: these shares sum past 2^64 back to exactly 10000; the
	// per-share <=10000 bound must refuse them before the sum can wrap
	uassert.AbortsWithMessage(t, cur,
		"invalid share value: 1152921505606846976",
		func() {
			CreateSplit(cross(cur), addrList(alice, bob, carol),
				"1152921505606846976,8646911284051357320,8646911284051357320")
		},
	)
	uassert.AbortsWithMessage(t, cur,
		"invalid share value: 10001",
		func() { CreateSplit(cross(cur), addrList(alice, bob), "10001,10000") },
	)
}

func TestArchiveFreesActiveListAndOwnerSlot(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	id := CreateSplit(cross(cur), addrList(alice), "10000")
	Archive(cross(cur), id)
	uassert.Equal(t, 1, len(splits), "archived entry stays for audit")
	uassert.Equal(t, 0, len(splitIDs), "archived entry frees the active list")
	CreateSplit(cross(cur), addrList(alice), "10000") // must not abort
}

func TestNoGlobalCap_SybilsCannotBlockOthers(cur realm, t *testing.T) {
	resetState()

	// round-4 P2: with per-owner quotas only, other owners filling their
	// own budgets never block a legitimate creator
	for i := 0; i < 30; i++ {
		syb := testutils.TestAddress("sybil_" + strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(syb))
		for j := 0; j < MaxSplitsPerOwner; j++ {
			CreateSplit(cross(cur), addrList(alice), "10000")
		}
	}
	uassert.Equal(t, 300, len(splitIDs))

	testing.SetRealm(testing.NewUserRealm(owner))
	CreateSplit(cross(cur), addrList(alice), "10000") // must not abort
}

func TestPreParseInputBounds(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	// round-4 P2: oversized inputs must be refused BEFORE parsing work
	uassert.AbortsWithMessage(t, cur,
		"recipient list too long",
		func() { CreateSplit(cross(cur), strings.Repeat(",", MaxRecipientListLen+1), "10000") },
	)
	uassert.AbortsWithMessage(t, cur,
		"share list too long",
		func() { CreateSplit(cross(cur), addrList(alice), strings.Repeat("1,", MaxShareListLen)) },
	)
}

func TestStraySendRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 100)

	// re-audit P3: coins attached to a non-Deposit call must abort (and
	// therefore revert to the sender), never strand on the realm address
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 50}})
	uassert.AbortsWithMessage(t, cur,
		"this function does not accept coins; attach coins to Deposit only",
		func() { Claim(cross(cur), id) },
	)
	testing.SetOriginSend(nil)

	// without coins attached the same claim succeeds
	uassert.Equal(t, int64(100), Claim(cross(cur), id))
}

func TestDeposit_CodeRealmRefused(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	// re-audit P1 companion: only a direct user MsgCall may deposit — a
	// code realm as previous realm must be refused (its send would not
	// have landed here). The MsgRun/ephemeral shape (the other half of
	// the IsUserCall-not-IsUser rationale) cannot be constructed in this
	// driver: SetRealm accepts only user realms and /r/ code realms
	// (NewCodeRealm rejects /e/ paths), so the predicate choice is
	// pinned here via the code-realm branch and verified live on-chain.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/intermediary"))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 100}})
	uassert.AbortsContains(t, cur,
		"deposits must be sent by direct call",
		func() { Deposit(cross(cur), id) },
	)
	testing.SetOriginSend(nil)
}

// ---------- round-3 audit regressions (2026-09-02) ----------

func TestUppercaseAddressesRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	// round-3 P2: all-uppercase bech32 passes IsValid but can never
	// match caller(): as a recipient it locks funds and blocks Archive;
	// as upper/lower twins it bypasses the duplicate check; as an owner
	// it orphans the split
	upper := strings.ToUpper(string(alice))
	uassert.AbortsWithMessage(t, cur,
		"invalid recipient address: "+upper,
		func() { CreateSplit(cross(cur), string(alice)+","+upper, "5000,5000") },
	)

	id := CreateSplit(cross(cur), addrList(alice), "10000")
	uassert.AbortsWithMessage(t, cur,
		"invalid new owner address: "+upper,
		func() { TransferOwnership(cross(cur), id, address(upper)) },
	)
}

func TestRender_OnlyArchivedSplits(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	Archive(cross(cur), id)

	uassert.Equal(t, "# Fee Split\n\nNo active splits.\n", Render(""),
		"archived-only state must render as no active splits")
}

// ---------- protocol fee (2026-09-03) ----------

func TestFee_DefaultZeroAndCap(cur realm, t *testing.T) {
	resetState()
	uassert.Equal(t, int64(0), feeBps)

	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	uassert.AbortsContains(t, cur, "fee must be between 0 and",
		func() { SetFee(cross(cur), MaxFeeBps+1) })
	uassert.AbortsContains(t, cur, "fee must be between 0 and",
		func() { SetFee(cross(cur), -1) })
	SetFee(cross(cur), MaxFeeBps) // exactly the cap is allowed
	uassert.Equal(t, MaxFeeBps, feeBps)

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur, "only the fee admin can set the fee",
		func() { SetFee(cross(cur), 1) })
}

func TestFee_TakenFromDepositNetAccounting(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	SetFee(cross(cur), 50) // 0.5%

	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")
	deposit(cur, owner, id, 10000)

	s := splits[id]
	// fee 50 off the top; 9950 net distributed (4975 + 4975)
	uassert.Equal(t, int64(50), feesAccrued)
	uassert.Equal(t, int64(9950), s.TotalDeposited)
	uassert.Equal(t, int64(4975), s.Balances[alice])
	uassert.Equal(t, int64(4975), s.Balances[bob])
	// conservation on net amounts holds untouched
	uassert.Equal(t, s.TotalDeposited, s.Balances[alice]+s.Balances[bob]+s.TotalClaimed)
}

func TestFee_NeverRetroactive(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 10000) // fee 0 at deposit time

	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	SetFee(cross(cur), MaxFeeBps)

	// the previously credited balance is untouched by the fee change
	uassert.Equal(t, int64(10000), splits[id].Balances[alice])
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(10000), Claim(cross(cur), id))
}

func TestFee_ClaimFeesSendsCoins(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	SetFee(cross(cur), 100) // 1%

	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 50000) // fee 500

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur, "only the fee admin can claim fees",
		func() { ClaimFees(cross(cur)) })

	before := banker.NewReadonlyBanker().GetCoins(feeAdminAddr).AmountOf(Denom)
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	uassert.Equal(t, int64(500), ClaimFees(cross(cur)))
	after := banker.NewReadonlyBanker().GetCoins(feeAdminAddr).AmountOf(Denom)
	uassert.Equal(t, int64(500), after-before)
	uassert.Equal(t, int64(0), feesAccrued)
	uassert.Equal(t, int64(500), feesClaimed)

	uassert.AbortsWithMessage(t, cur, "no fees accrued", func() { ClaimFees(cross(cur)) })
}

func TestFee_TinyDepositFullyConsumedRefused(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	SetFee(cross(cur), MaxFeeBps) // 1%

	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	// amounts < 100 at 1% round the fee to 0 — deposit passes whole
	deposit(cur, owner, id, 99)
	uassert.Equal(t, int64(0), feesAccrued)
	uassert.Equal(t, int64(99), splits[id].Balances[alice])
}

func TestFee_TwoStepAdminHandover(cur realm, t *testing.T) {
	resetState()
	newAdmin := testutils.TestAddress("newfeeadmin")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur, "only the fee admin can nominate a successor",
		func() { NominateFeeAdmin(cross(cur), attacker) })

	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	uassert.AbortsContains(t, cur, "invalid nominee address",
		func() { NominateFeeAdmin(cross(cur), address("JUNK")) })
	NominateFeeAdmin(cross(cur), newAdmin)
	// nomination alone changes nothing
	uassert.Equal(t, string(feeAdminAddr), string(feeAdmin))

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t, cur, "caller is not the pending fee admin",
		func() { AcceptFeeAdmin(cross(cur)) })

	testing.SetRealm(testing.NewUserRealm(newAdmin))
	AcceptFeeAdmin(cross(cur))
	uassert.Equal(t, string(newAdmin), string(feeAdmin))
	uassert.Equal(t, "", string(pendingFeeAdmin))

	// clearing a nomination works
	testing.SetRealm(testing.NewUserRealm(newAdmin))
	NominateFeeAdmin(cross(cur), feeAdminAddr)
	NominateFeeAdmin(cross(cur), "")
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	uassert.AbortsWithMessage(t, cur, "caller is not the pending fee admin",
		func() { AcceptFeeAdmin(cross(cur)) })
}

func TestFee_StraySendRejectedOnFeeFunctions(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 5}})
	uassert.AbortsWithMessage(t, cur,
		"this function does not accept coins; attach coins to Deposit only",
		func() { SetFee(cross(cur), 10) },
	)
	testing.SetOriginSend(nil)
}

// ---------- round-5 audit regressions (fee path, 2026-09-03) ----------

// Pins the benign-degradation safety property: an empty fee admin (the
// gno-test-VM init state, and any hypothetical empty-origin deploy)
// leaves the fee permanently disabled and zero funds at risk — SetFee
// can never be authorized, so feeBps stays 0 and nothing accrues.
func TestFee_EmptyAdminDegradesToDisabled(cur realm, t *testing.T) {
	resetState()
	feeAdmin = ""
	feeBps = 0

	for _, who := range []address{owner, alice, feeAdminAddr, attacker} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsWithMessage(t, cur, "only the fee admin can set the fee",
			func() { SetFee(cross(cur), 100) })
	}
	uassert.Equal(t, int64(0), feeBps, "fee must remain 0 with no reachable admin")

	// a deposit accrues nothing
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 10000)
	uassert.Equal(t, int64(0), feesAccrued)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(10000), Claim(cross(cur), id)) // full amount, no fee
}

// Fees accrued before a handover are claimable by the NEW admin
// (documented semantics: claim before transferring if that matters).
func TestFee_HandoverTransfersAccruedClaimRight(cur realm, t *testing.T) {
	resetState()
	newFa := testutils.TestAddress("newfa")
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	SetFee(cross(cur), 100)
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 100000) // 1000 accrued under the original admin

	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	NominateFeeAdmin(cross(cur), newFa)
	testing.SetRealm(testing.NewUserRealm(newFa))
	AcceptFeeAdmin(cross(cur))
	uassert.Equal(t, int64(1000), ClaimFees(cross(cur)), "new admin claims prior-regime fees")

	// the old admin can no longer claim — fails the authorization check
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	uassert.AbortsWithMessage(t, cur, "only the fee admin can claim fees", func() { ClaimFees(cross(cur)) })
}

// Every fee function rejects an attached send (only SetFee was pinned).
func TestFee_AllFunctionsRejectStraySend(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(feeAdminAddr))
	send := chain.Coins{{Denom: Denom, Amount: 3}}
	msg := "this function does not accept coins; attach coins to Deposit only"

	testing.SetOriginSend(send)
	uassert.AbortsWithMessage(t, cur, msg, func() { SetFee(cross(cur), 10) })
	uassert.AbortsWithMessage(t, cur, msg, func() { NominateFeeAdmin(cross(cur), attacker) })
	uassert.AbortsWithMessage(t, cur, msg, func() { ClaimFees(cross(cur)) })
	testing.SetOriginSend(nil)

	// AcceptFeeAdmin from the pending side, also with a send
	NominateFeeAdmin(cross(cur), attacker)
	testing.SetRealm(testing.NewUserRealm(attacker))
	testing.SetOriginSend(send)
	uassert.AbortsWithMessage(t, cur, msg, func() { AcceptFeeAdmin(cross(cur)) })
	testing.SetOriginSend(nil)
}

// ---------- audit round-1 gap closures (2026-09-21) ----------

func TestStraySendRejectedOnAllSplitFunctions(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")

	// audit Y2 gap 2: only Claim and the fee functions were pinned; the
	// five split-management functions call the same guard — prove it
	msg := "this function does not accept coins; attach coins to Deposit only"
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 7}})
	uassert.AbortsWithMessage(t, cur, msg, func() { CreateSplit(cross(cur), addrList(carol), "10000") })
	uassert.AbortsWithMessage(t, cur, msg, func() { UpdateShares(cross(cur), id, addrList(alice), "10000") })
	uassert.AbortsWithMessage(t, cur, msg, func() { TransferOwnership(cross(cur), id, carol) })
	uassert.AbortsWithMessage(t, cur, msg, func() { AcceptOwnership(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Freeze(cross(cur), id) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Archive(cross(cur), id) })
	testing.SetOriginSend(nil)
}

func TestArchivedSplitRefusesDepositAndClaim(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")
	deposit(cur, owner, id, 100)
	testing.SetRealm(testing.NewUserRealm(alice))
	Claim(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(owner))
	Archive(cross(cur), id)

	// audit Y2 gap 3: the terminal state must refuse both value paths
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 50}})
	uassert.AbortsWithMessage(t, cur, "split is archived: "+id,
		func() { Deposit(cross(cur), id) })
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "split is archived: "+id,
		func() { Claim(cross(cur), id) })
}

func TestDeposit_TwoCoinEnvelopeRejected(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice), "10000")

	// audit Y2 gap 4: only zero-coin and wrong-denom were pinned; a
	// two-coin envelope must also be refused by the exact len==1 check
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 100}, {Denom: "ufoo", Amount: 1}})
	uassert.AbortsWithMessage(t, cur,
		"deposit must send exactly one coin of "+Denom,
		func() { Deposit(cross(cur), id) })
	testing.SetOriginSend(nil)
	uassert.Equal(t, int64(0), splits[id].TotalDeposited)
}

func TestDust_EqualShareTieGoesToFirst(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateSplit(cross(cur), addrList(alice, bob), "5000,5000")

	// audit Y2 gap 5: the dust rule at an exact share tie is
	// first-listed-wins (strict > never replaces dustIdx) — pin it
	deposit(cur, owner, id, 101)
	uassert.Equal(t, int64(51), splits[id].Balances[alice])
	uassert.Equal(t, int64(50), splits[id].Balances[bob])
}
