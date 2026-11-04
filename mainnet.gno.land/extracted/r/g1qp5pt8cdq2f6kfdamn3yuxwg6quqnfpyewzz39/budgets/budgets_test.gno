package budgets

import (
	"strings"
	"testing"

	"chain"

	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/coinio"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	owner1    = testutils.TestAddress("bgowner1")
	owner2    = testutils.TestAddress("bgowner2")
	delegate1 = testutils.TestAddress("bgdeleg1")
	delegate2 = testutils.TestAddress("bgdeleg2")
	mallory   = testutils.TestAddress("bgmallory")
)

// HARNESS NOTES, carried from the crowdfund, treasury_board and vesting
// suites (measured there, relied on here):
//
//   - testing.SetRealm records the override per FRAME INDEX: stage the
//     caller INLINE in this test function's own frame before a uassert
//     call, or inside a helper that stages and calls in one frame of its
//     own. Never inside a uassert closure — that staging does not take.
//
//   - testing.SkipHeights REPLACES the whole context (OriginCaller,
//     CurrentRealm, OriginSend included). Re-stage after every skip.
//
//   - Realm globals PERSIST across tests while banker state resets per
//     test. begin() disarms any leftover envelope and re-seeds the
//     realm's bank to its carried liabilities, so solvency is asserted in
//     DELTA form and every test tidies up after itself.
//
//   - A panic caught by uassert does NOT roll back realm globals here,
//     whereas on-chain the whole transaction reverts. Every abort
//     asserted below happens strictly BEFORE this realm writes state, and
//     the one case where that is the POINT of the test
//     (TestDrawSolvencyRefusalConsumesNothing) asserts the untouched
//     state directly rather than relying on a rollback that does not
//     happen in this harness.
//
//   - The SEND envelope is process-global: a staged envelope must be
//     cleared (SetOriginSend(nil)) before the next non-payable call, or
//     rejectStraySend fires and the test asserts the harness leak instead
//     of the guard.
//
// unsafe.CurrentRealm() is not available to a unit test, so `self` is
// seeded from the package path the same way the chain derives it.
func init() {
	self = chain.PackageAddress(
		"gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/budgets")
}

type baseline struct {
	held   int64
	pooled int64
	credit int64
	fees   int64
}

func begin() baseline {
	testing.SetOriginSend(nil)
	if l := Liabilities(); l > 0 {
		testing.IssueCoins(Address(), ugnot(l))
	}
	return baseline{
		held:   Held(),
		pooled: TotalPooled(),
		credit: UnclaimedCredit(),
		fees:   FeesAccrued(),
	}
}

func ugnot(n int64) chain.Coins {
	return chain.NewCoins(chain.NewCoin(Denom, n))
}

// assertSolvent asserts the two halves of H == P + L + S that can actually
// FAIL. The identity itself is definitional here, because Surplus() is
// defined as Held() - Liabilities(), so asserting it would be a tautology
// dressed as a check. What can fail is that the realm owes more than it
// holds, and that L decomposes exactly into delegate credit plus the fee
// pot — neither of which follows from any definition in this file.
// It also re-derives the P term the slow way. totalPooled is maintained
// O(1) for Render's sake, so it is a CACHE of the pools tree, and nothing
// in the realm ever recomputes it — exactly the shape that drifts silently.
// Sabotage found this gap rather than review: disabling the per-owner debit
// in Draw while leaving totalPooled correct was detected only by a later
// native-Go banker panic, never by an assertion.
func assertSolvent(t *testing.T) {
	uassert.True(t, Held() >= Liabilities())
	uassert.Equal(t, TotalPooled()+UnclaimedCredit()+FeesAccrued(), Liabilities())

	sum := int64(0)
	pools.Iterate("", "", func(_ string, v any) bool {
		n := v.(int64)
		// setPool removes a zeroed entry rather than storing it, so every
		// surviving entry must be strictly positive.
		uassert.True(t, n > 0)
		sum += n
		return false
	})
	uassert.Equal(t, sum, TotalPooled())
}

// fundAs stages a direct EOA call with -send and mirrors the envelope into
// the realm's bank, as the chain would.
func fundAs(cur realm, from address, amount int64) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginSend(ugnot(amount))
	testing.IssueCoins(Address(), ugnot(amount))
	n := Fund(cross(cur))
	testing.SetOriginSend(nil)
	return n
}

func grantAs(cur realm, from, spender address,
	perPeriod, periodLength, total, expiresAt int64) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	return Grant(cross(cur), spender, "", perPeriod, periodLength, total, expiresAt)
}

func drawAs(cur realm, from address, id, amount int64) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	return Draw(cross(cur), id, amount)
}

func claimAs(cur realm, from address) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	return Claim(cross(cur))
}

func revokeAs(cur realm, from address, id int64) {
	testing.SetRealm(testing.NewUserRealm(from))
	Revoke(cross(cur), id)
}

func withdrawAllAs(cur realm, from address) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	return WithdrawPoolAll(cross(cur))
}

func balanceOf(addr address) int64 {
	return coinio.HeldAt(addr, Denom)
}

// --- the pool ---

func TestFundMakesAnOwner(cur realm, t *testing.T) {
	b := begin()
	uassert.Equal(t, int64(0), PoolOf(owner1))

	pool := fundAs(cur, owner1, MinFunding)
	uassert.Equal(t, MinFunding, pool)
	uassert.Equal(t, MinFunding, PoolOf(owner1))
	uassert.Equal(t, b.pooled+MinFunding, TotalPooled())
	uassert.Equal(t, b.held+MinFunding, Held())
	uassert.Equal(t, b.credit, UnclaimedCredit())
	uassert.Equal(t, b.fees, FeesAccrued())
	assertSolvent(t)

	// Funding again accumulates into the same pool.
	pool = fundAs(cur, owner1, 2*MinFunding)
	uassert.Equal(t, 3*MinFunding, pool)
	uassert.Equal(t, b.pooled+3*MinFunding, TotalPooled())

	// A second owner's pool is independent.
	fundAs(cur, owner2, MinFunding)
	uassert.Equal(t, 3*MinFunding, PoolOf(owner1))
	uassert.Equal(t, MinFunding, PoolOf(owner2))
	assertSolvent(t)

	uassert.Equal(t, 3*MinFunding, withdrawAllAs(cur, owner1))
	uassert.Equal(t, MinFunding, withdrawAllAs(cur, owner2))
	uassert.Equal(t, b.pooled, TotalPooled())
	// setPool removes a zeroed entry rather than storing 0.
	uassert.Equal(t, int64(0), PoolOf(owner1))
}

func TestFundGuards(cur realm, t *testing.T) {
	begin()

	// coinio's receipt shape: a realm-routed payment is refused by the
	// primitive, not by anything this file could forget to write.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/attacker"))
	testing.SetOriginSend(ugnot(MinFunding))
	uassert.AbortsWithMessage(t, cur,
		"coinio: payment must be a direct EOA call with -send (realms and maketx-run are rejected)",
		func() { Fund(cross(cur)) })
	testing.SetOriginSend(nil)

	// Wrong denomination.
	testing.SetRealm(testing.NewUserRealm(owner1))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("foocoin", MinFunding)))
	uassert.AbortsWithMessage(t, cur, "coinio: send exactly one coin type: ugnot",
		func() { Fund(cross(cur)) })
	testing.SetOriginSend(nil)

	// No envelope at all.
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "coinio: send exactly one coin type: ugnot",
		func() { Fund(cross(cur)) })

	// Below the minimum. Not issued into the bank, so the refused call
	// leaves no surplus behind.
	testing.SetRealm(testing.NewUserRealm(owner1))
	testing.SetOriginSend(ugnot(MinFunding - 1))
	uassert.AbortsWithMessage(t, cur, "fund at least 1000000ugnot",
		func() { Fund(cross(cur)) })
	testing.SetOriginSend(nil)

	uassert.Equal(t, int64(0), PoolOf(owner1))
	assertSolvent(t)
}

func TestWithdrawPoolIsUnconditional(cur realm, t *testing.T) {
	b := begin()
	fundAs(cur, owner1, 3*MinFunding)
	before := balanceOf(owner1)

	testing.SetRealm(testing.NewUserRealm(owner1))
	left := WithdrawPool(cross(cur), MinFunding)
	uassert.Equal(t, 2*MinFunding, left)
	uassert.Equal(t, before+MinFunding, balanceOf(owner1))
	uassert.Equal(t, b.pooled+2*MinFunding, TotalPooled())
	assertSolvent(t)

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "amount exceeds pool",
		func() { WithdrawPool(cross(cur), 2*MinFunding+1) })

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "amount must be positive",
		func() { WithdrawPool(cross(cur), 0) })

	// A non-owner has no pool to take, and mallory cannot reach owner1's.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "no pool to withdraw",
		func() { WithdrawPoolAll(cross(cur)) })
	uassert.Equal(t, 2*MinFunding, PoolOf(owner1))

	uassert.Equal(t, 2*MinFunding, withdrawAllAs(cur, owner1))
	uassert.Equal(t, b.pooled, TotalPooled())
	assertSolvent(t)
}

// TestOwnerCanAlwaysLeave pins the documented consequence of that design:
// an owner may empty the pool under a LIVE grant, and the delegate's next
// draw then fails on solvency rather than being trapped half-way. A realm
// that locked the capital behind the grant would be the worse realm, and
// this test is here so the behaviour cannot drift silently either way.
func TestOwnerCanAlwaysLeave(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 500_000, MinPeriodBlocks, 0, 0)

	uassert.Equal(t, int64(500_000), Drawable(id))
	withdrawAllAs(cur, owner1)
	uassert.Equal(t, int64(0), PoolOf(owner1))

	// The AUTHORITY is untouched; only the honest figure moved.
	uassert.Equal(t, int64(500_000), Remaining(id))
	uassert.Equal(t, int64(0), Drawable(id))

	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "owner's pool cannot cover this draw",
		func() { Draw(cross(cur), id, 1_000) })

	revokeAs(cur, owner1, id)
	assertSolvent(t)
}

// TestSelfGrantRecoversThePoolForTheFeeAlone pins the premise that the
// MaxLiveGrants comment rests on, and it exists because the claim that
// comment USED to make rotted undetected until an adversarial audit read
// it (finding Y1). The lesson was not "that number was wrong" but "a
// mitigation asserted nowhere is prose", so the replacement reasoning is
// asserted here.
//
// The reasoning is that no capital bound on grant-slot occupation can be
// built out of the pool, because an owner may be its OWN delegate. Make
// an owner retain MinFunding while grants are live and this is the way
// around it: grant to yourself, draw the pool to zero through your own
// grant, Claim the credit back. You recover everything but the draw fee,
// the slot is still held, and a retention rule reads as satisfied the
// whole way through. The realm permits this deliberately — refusing a
// self-grant would not close it either, since a second address the same
// operator controls is free.
func TestSelfGrantRecoversThePoolForTheFeeAlone(cur realm, t *testing.T) {
	begin()
	feesBefore := FeesAccrued()

	fundAs(cur, owner1, MinFunding)
	// owner1 is both parties. Nothing refuses it.
	id := grantAs(cur, owner1, owner1, MinFunding, MinPeriodBlocks, 0, 0)

	// Drain the whole pool through the owner's own grant.
	credited := drawAs(cur, owner1, id, MinFunding)
	fee := MinFunding * DrawFeeBps / 10_000
	uassert.Equal(t, MinFunding-fee, credited)
	uassert.Equal(t, int64(0), PoolOf(owner1))

	// ... and take it back out. Net cost of holding the slot: the fee.
	uassert.Equal(t, MinFunding-fee, claimAs(cur, owner1))
	uassert.Equal(t, feesBefore+fee, FeesAccrued())

	// The slot is still occupied, which is the whole point: the grant
	// survived the pool reaching zero, and no third party can remove it
	// because it carries no expiry.
	uassert.Equal(t, int64(1), ownerOpen(owner1.String()))
	uassert.False(t, IsExpired(id))
	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: allowance has not expired",
		func() { Reap(cross(cur), id) })

	revokeAs(cur, owner1, id)
	uassert.Equal(t, int64(0), ownerOpen(owner1.String()))
	assertSolvent(t)
}

// --- grants ---

func TestGrantRecordsTermsAndParties(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	h := Height()
	liveBefore := LiveGrants()

	testing.SetRealm(testing.NewUserRealm(owner1))
	id := Grant(cross(cur), delegate1, "monthly ops", 50_000, MinPeriodBlocks,
		200_000, h+500)

	uassert.Equal(t, id, NumGrants())
	uassert.Equal(t, liveBefore+1, LiveGrants())
	uassert.Equal(t, int64(1), GrantsOf(owner1))
	uassert.Equal(t, "monthly ops", GrantLabel(id))

	o, s, perPeriod, periodLength, total, expiresAt, anchor, createdAt, feeBps :=
		GrantInfo(id)
	uassert.Equal(t, owner1, o)
	uassert.Equal(t, delegate1, s)
	uassert.Equal(t, int64(50_000), perPeriod)
	uassert.Equal(t, MinPeriodBlocks, periodLength)
	uassert.Equal(t, int64(200_000), total)
	uassert.Equal(t, h+500, expiresAt)
	// The anchor is the grant height: windows are anchored, not sliding,
	// so nobody resets a cap by choosing when to call.
	uassert.Equal(t, h, anchor)
	uassert.Equal(t, h, createdAt)
	uassert.Equal(t, DrawFeeBps, feeBps)

	spentWindow, spentTotal, windowIndex, draws := GrantUsage(id)
	uassert.Equal(t, int64(0), spentWindow)
	uassert.Equal(t, int64(0), spentTotal)
	uassert.Equal(t, int64(0), windowIndex)
	uassert.Equal(t, int64(0), draws)

	uassert.False(t, IsExpired(id))

	revokeAs(cur, owner1, id)
	uassert.Equal(t, int64(0), GrantsOf(owner1))
	uassert.Equal(t, liveBefore, LiveGrants())
	withdrawAllAs(cur, owner1)
}

func TestGrantValidation(cur realm, t *testing.T) {
	begin()

	// No pool: a grant from an address with nothing behind it is refused
	// before any allowance is opened.
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "fund a pool before granting",
		func() { Grant(cross(cur), delegate1, "", 50_000, MinPeriodBlocks, 0, 0) })

	fundAs(cur, owner1, MinFunding)

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur,
		"spender is not a valid address in canonical (lowercase) form",
		func() { Grant(cross(cur), address("not-an-address"), "", 50_000, MinPeriodBlocks, 0, 0) })

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "label exceeds 64 bytes",
		func() {
			Grant(cross(cur), delegate1, strings.Repeat("x", MaxLabelLen+1),
				50_000, MinPeriodBlocks, 0, 0)
		})

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "perPeriod must be at least 1000ugnot",
		func() { Grant(cross(cur), delegate1, "", MinPerPeriod-1, MinPeriodBlocks, 0, 0) })

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur,
		"periodLength must be 0 (lifetime) or at least 100 blocks",
		func() { Grant(cross(cur), delegate1, "", 50_000, MinPeriodBlocks-1, 0, 0) })

	// An expiry already in the past is spendbook's own refusal: an
	// allowance that can authorize nothing must not become a live entry.
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "spendbook: invalid terms",
		func() { Grant(cross(cur), delegate1, "", 50_000, MinPeriodBlocks, 0, 1) })

	uassert.Equal(t, int64(0), GrantsOf(owner1))
	withdrawAllAs(cur, owner1)
}

// TestGrantRefusesUppercaseSpender measures the premise of Grant's
// lowercase clause rather than asserting it from the bech32 spec. If
// IsValid() ever stops accepting the uppercase spelling, the first
// assertion here fails and the clause's comment must be corrected — which
// is the point of measuring it.
func TestGrantRefusesUppercaseSpender(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)

	upper := address(strings.ToUpper(string(delegate1)))
	uassert.True(t, upper != delegate1)
	uassert.True(t, upper.IsValid()) // the hazard, measured on this toolchain

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur,
		"spender is not a valid address in canonical (lowercase) form",
		func() { Grant(cross(cur), upper, "", 50_000, MinPeriodBlocks, 0, 0) })

	uassert.Equal(t, int64(0), GrantsOf(owner1))
	withdrawAllAs(cur, owner1)
}

// TestGrantPerOwnerCap covers the gap spendbook's own documentation names:
// maxLive is a single global figure, so without a per-owner cap one owner
// could exhaust it and lock everyone else out.
func TestGrantPerOwnerCap(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)

	ids := []int64{}
	for i := int64(0); i < MaxGrantsPerOwner; i++ {
		ids = append(ids, grantAs(cur, owner1, delegate1, MinPerPeriod,
			MinPeriodBlocks, 0, 0))
	}
	uassert.Equal(t, MaxGrantsPerOwner, GrantsOf(owner1))

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "owner already has 16 live grants",
		func() { Grant(cross(cur), delegate1, "", MinPerPeriod, MinPeriodBlocks, 0, 0) })

	// A DIFFERENT owner is unaffected — the cap is per-owner, not global.
	fundAs(cur, owner2, MinFunding)
	other := grantAs(cur, owner2, delegate2, MinPerPeriod, MinPeriodBlocks, 0, 0)
	uassert.Equal(t, int64(1), GrantsOf(owner2))

	// Revoking frees a slot, and the id is not reused.
	revokeAs(cur, owner1, ids[0])
	uassert.Equal(t, MaxGrantsPerOwner-1, GrantsOf(owner1))
	fresh := grantAs(cur, owner1, delegate1, MinPerPeriod, MinPeriodBlocks, 0, 0)
	uassert.True(t, fresh > ids[len(ids)-1])

	for _, id := range ids[1:] {
		revokeAs(cur, owner1, id)
	}
	revokeAs(cur, owner1, fresh)
	revokeAs(cur, owner2, other)
	uassert.Equal(t, int64(0), GrantsOf(owner1))
	uassert.Equal(t, int64(0), GrantsOf(owner2))
	withdrawAllAs(cur, owner1)
	withdrawAllAs(cur, owner2)
	assertSolvent(t)
}

func TestGrantAndAmendAreOwnerOnly(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 50_000, MinPeriodBlocks, 0, 0)

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "owner only",
		func() { Amend(cross(cur), id, 10_000, 0, 0) })

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "owner only",
		func() { Revoke(cross(cur), id) })

	// Not even the delegate may amend or revoke their own grant.
	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "owner only",
		func() { Amend(cross(cur), id, 10_000, 0, 0) })

	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "unknown grant id",
		func() { Revoke(cross(cur), 999_999) })

	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
}

// --- drawing ---

func TestDrawIsDelegateOnlyAndCreditsNetOfFee(cur realm, t *testing.T) {
	b := begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 500_000, MinPeriodBlocks, 0, 0)

	// Nobody but the named delegate — not mallory, and not the owner.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "delegate only",
		func() { Draw(cross(cur), id, 1_000) })
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "delegate only",
		func() { Draw(cross(cur), id, 1_000) })

	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "amount must be positive",
		func() { Draw(cross(cur), id, 0) })

	heldBefore := Held()
	credited := drawAs(cur, delegate1, id, 100_000)

	// 1% of the gross, floor-rounded in the delegate's favour.
	uassert.Equal(t, int64(99_000), credited)
	uassert.Equal(t, int64(99_000), CreditOf(delegate1))
	uassert.Equal(t, b.fees+1_000, FeesAccrued())

	// The owner's pool is debited the GROSS: the fee is paid out of the
	// budget, not out of the delegate's authority.
	uassert.Equal(t, MinFunding-100_000, PoolOf(owner1))
	uassert.Equal(t, b.pooled+MinFunding-100_000, TotalPooled())

	// Draw moves value between P and L only. H does not move at all, which
	// is why this transition has no payout that could fail.
	uassert.Equal(t, heldBefore, Held())
	assertSolvent(t)

	spentWindow, spentTotal, _, draws := GrantUsage(id)
	uassert.Equal(t, int64(100_000), spentWindow)
	uassert.Equal(t, int64(100_000), spentTotal)
	uassert.Equal(t, int64(1), draws)
	uassert.Equal(t, int64(400_000), Remaining(id))

	// Claim is the separate transaction that moves coins.
	before := balanceOf(delegate1)
	paid := claimAs(cur, delegate1)
	uassert.Equal(t, int64(99_000), paid)
	uassert.Equal(t, before+99_000, balanceOf(delegate1))
	uassert.Equal(t, int64(0), CreditOf(delegate1))
	uassert.Equal(t, b.credit, UnclaimedCredit())
	assertSolvent(t)

	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "no credit to claim",
		func() { Claim(cross(cur)) })

	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

// TestDrawSolvencyRefusalConsumesNothing is this realm's central
// invariant, and the ordering inside Draw is what it proves: the solvency
// check runs BEFORE spendbook.Spend, so a draw refused for insolvency
// leaves the window capacity intact rather than burning it on a draw that
// never happened.
//
// This is also the one abort in this file where the post-state is the
// assertion rather than an afterthought, because uassert does not roll
// back realm globals the way a reverted transaction would.
func TestDrawSolvencyRefusalConsumesNothing(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	// Authority deliberately EXCEEDS the pool: a budget is authority, not
	// a reservation, and the realm's promise is that it never credits what
	// it cannot pay.
	id := grantAs(cur, owner1, delegate1, 5*MinFunding, MinPeriodBlocks, 0, 0)
	uassert.Equal(t, 5*MinFunding, Remaining(id))
	uassert.Equal(t, MinFunding, Drawable(id)) // the honest figure

	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "owner's pool cannot cover this draw",
		func() { Draw(cross(cur), id, MinFunding+1) })

	// Nothing moved, and — the part that matters — nothing was CONSUMED.
	spentWindow, spentTotal, _, draws := GrantUsage(id)
	uassert.Equal(t, int64(0), spentWindow)
	uassert.Equal(t, int64(0), spentTotal)
	uassert.Equal(t, int64(0), draws)
	uassert.Equal(t, 5*MinFunding, Remaining(id))
	uassert.Equal(t, MinFunding, PoolOf(owner1))
	uassert.Equal(t, int64(0), CreditOf(delegate1))
	assertSolvent(t)

	// Exactly the drawable figure succeeds, which is what makes the
	// refusal above a boundary rather than a blanket.
	uassert.Equal(t, int64(990_000), drawAs(cur, delegate1, id, MinFunding))
	uassert.Equal(t, int64(0), PoolOf(owner1))

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, id)
	tidyFees(cur, t)
	assertSolvent(t)
}

func TestDrawFeeRoundingFavorsTheDelegate(cur realm, t *testing.T) {
	b := begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 50_000, MinPeriodBlocks, 0, 0)

	// 1% of 99 floors to 0, so the delegate keeps all of it. There is
	// deliberately no minimum draw: a floor above a grant's PerPeriod
	// would make the grant silently undrawable.
	uassert.Equal(t, int64(99), drawAs(cur, delegate1, id, 99))
	uassert.Equal(t, b.fees, FeesAccrued())
	uassert.Equal(t, int64(99), CreditOf(delegate1))

	// 100 is the first amount that pays a fee at all.
	uassert.Equal(t, int64(99), drawAs(cur, delegate1, id, 100))
	uassert.Equal(t, b.fees+1, FeesAccrued())
	uassert.Equal(t, int64(198), CreditOf(delegate1))
	assertSolvent(t)

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

// TestWindowRefillsAtAnchoredBoundary is spendbook consumer obligation 1
// observed from the consuming side: the clock is runtime.ChainHeight() and
// no caller supplies it, so the window cannot be rolled on demand. The
// refill is a RESET, not a carry.
func TestWindowRefillsAtAnchoredBoundary(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, 10*MinFunding)
	id := grantAs(cur, owner1, delegate1, 100_000, MinPeriodBlocks, 0, 0)

	drawAs(cur, delegate1, id, 100_000)
	uassert.Equal(t, int64(0), Remaining(id))

	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: amount exceeds the window cap",
		func() { Draw(cross(cur), id, 1) })

	// One block short of the boundary: still refused.
	testing.SkipHeights(MinPeriodBlocks - 1)
	uassert.Equal(t, int64(0), Remaining(id))
	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: amount exceeds the window cap",
		func() { Draw(cross(cur), id, 1) })

	// The boundary itself. The window index advances and the cap is full
	// again — not 100_000 plus a carried remainder.
	testing.SkipHeights(1)
	uassert.Equal(t, int64(100_000), Remaining(id))
	_, _, windowIndex, _ := GrantUsage(id)
	uassert.Equal(t, int64(1), windowIndex)

	// THE STALE-PAIR CASE, and it is asserted here rather than left to
	// inference because this is the only moment it is observable: the
	// chain has crossed a boundary and NOTHING has been written since, so
	// Allowance.WindowIndex still names window 0 and Allowance.SpentWindow
	// still holds window 0's 100_000. Reading either field straight off
	// the record would publish "spent this window: 100000" directly above
	// "authorized by the terms: 100000" — a page contradicting itself.
	// spentInWindow is what makes the first figure 0, and this assertion
	// is what keeps it that way.
	staleWindow, _, _, _ := GrantUsage(id)
	uassert.Equal(t, int64(0), staleWindow)
	page := Render(itoa(id))
	uassert.True(t, strings.Contains(page, "spent this window: 0ugnot"))
	uassert.True(t, strings.Contains(page, "now in window 1"))

	drawAs(cur, delegate1, id, 100_000)
	_, spentTotal, _, draws := GrantUsage(id)
	uassert.Equal(t, int64(200_000), spentTotal) // lifetime accumulates
	uassert.Equal(t, int64(2), draws)
	spentWindow, _, _, _ := GrantUsage(id)
	uassert.Equal(t, int64(100_000), spentWindow) // the window reset
	assertSolvent(t)

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

func TestLifetimeTotalBindsAcrossARollover(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, 10*MinFunding)
	// Lifetime cap at 1.5 windows: the refill cannot outrun it.
	id := grantAs(cur, owner1, delegate1, 100_000, MinPeriodBlocks, 150_000, 0)

	drawAs(cur, delegate1, id, 100_000)
	testing.SkipHeights(MinPeriodBlocks)

	// The window refilled to 100_000 but the lifetime cap leaves 50_000,
	// and Remaining reports the LESSER of the two.
	uassert.Equal(t, int64(50_000), Remaining(id))
	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: amount exceeds the lifetime cap",
		func() { Draw(cross(cur), id, 50_001) })

	drawAs(cur, delegate1, id, 50_000)
	uassert.Equal(t, int64(0), Remaining(id))

	// A further window brings no further authority: the lifetime cap is
	// absolute.
	testing.SkipHeights(MinPeriodBlocks)
	uassert.Equal(t, int64(0), Remaining(id))
	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: amount exceeds the lifetime cap",
		func() { Draw(cross(cur), id, 1) })
	assertSolvent(t)

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

// TestLifetimeWindowNeverRefills covers periodLength == 0: ONE window for
// the grant's whole life. It is a distinct code path in spendbook
// (windowIndex is pinned to 0) and a distinct product shape — a one-off
// authority rather than a recurring budget.
func TestLifetimeWindowNeverRefills(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 100_000, 0, 0, 0)

	// GrantInfo's fourth result is periodLength; the third is perPeriod.
	_, _, _, periodLength, _, _, _, _, _ := GrantInfo(id)
	uassert.Equal(t, int64(0), periodLength)

	drawAs(cur, delegate1, id, 100_000)
	uassert.Equal(t, int64(0), Remaining(id))

	testing.SkipHeights(10 * MinPeriodBlocks)
	uassert.Equal(t, int64(0), Remaining(id))
	_, _, windowIndex, _ := GrantUsage(id)
	uassert.Equal(t, int64(0), windowIndex)

	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: amount exceeds the window cap",
		func() { Draw(cross(cur), id, 1) })

	// And a LOOSENING cannot be queued against a grant with no boundary to
	// wait for — spendbook refuses rather than accepting an amendment that
	// would never take effect.
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur,
		"spendbook: no reachable next window boundary",
		func() { Amend(cross(cur), id, 200_000, 0, 0) })
	assertSolvent(t)

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

// --- amendment ---

func TestAmendIsOneSided(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, 10*MinFunding)
	id := grantAs(cur, owner1, delegate1, 100_000, MinPeriodBlocks, 0, 0)

	// A TIGHTENING takes effect immediately, mid-window.
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.True(t, Amend(cross(cur), id, 20_000, 0, 0))
	uassert.Equal(t, int64(20_000), Remaining(id))
	_, _, pending := pendingOf(id)
	uassert.False(t, pending)

	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: amount exceeds the window cap",
		func() { Draw(cross(cur), id, 20_001) })

	// A LOOSENING is queued for the next boundary, not applied now. That
	// asymmetry is the whole guarantee: the delegate's exposure in the
	// current window can only ever shrink.
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.False(t, Amend(cross(cur), id, 300_000, 0, 0))
	uassert.Equal(t, int64(20_000), Remaining(id))
	perPeriod, _, pending := pendingOf(id)
	uassert.True(t, pending)
	uassert.Equal(t, int64(300_000), perPeriod)

	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: amount exceeds the window cap",
		func() { Draw(cross(cur), id, 20_001) })

	// At the boundary the pending terms become the live ones.
	testing.SkipHeights(MinPeriodBlocks)
	uassert.Equal(t, int64(300_000), Remaining(id))
	drawAs(cur, delegate1, id, 300_000)
	assertSolvent(t)

	// The realm's own floor still applies to an amendment.
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "perPeriod must be at least 1000ugnot",
		func() { Amend(cross(cur), id, MinPerPeriod-1, 0, 0) })

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

// TestAmendCannotMovePeriodLength asserts a STRUCTURAL property, not a
// refusal: Amend has no periodLength parameter at all, so moving every
// future boundary is not merely rejected, it is unexpressible. The realm
// reads the grant's own periodLength and passes it back unchanged.
func TestAmendCannotMovePeriodLength(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 100_000, MinPeriodBlocks, 0, 0)

	_, _, _, before, _, _, anchorBefore, _, _ := GrantInfo(id)
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.True(t, Amend(cross(cur), id, 10_000, 0, 0))
	_, _, _, after, _, _, anchorAfter, _, _ := GrantInfo(id)

	uassert.Equal(t, before, after)
	uassert.Equal(t, MinPeriodBlocks, after)
	// The anchor is immovable too, so the boundaries stay where they were.
	uassert.Equal(t, anchorBefore, anchorAfter)

	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
}

// --- ending a grant ---

func TestRevokeEndsAuthorityButNotEarnedCredit(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 100_000, MinPeriodBlocks, 0, 0)
	drawAs(cur, delegate1, id, 100_000)
	uassert.Equal(t, int64(99_000), CreditOf(delegate1))

	revokeAs(cur, owner1, id)

	// The grant record is gone and the id is never reused, so a later draw
	// fails as unknown rather than as unauthorized.
	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "unknown grant id",
		func() { Draw(cross(cur), id, 1) })
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.AbortsWithMessage(t, cur, "unknown grant id",
		func() { Revoke(cross(cur), id) })

	// Credit already drawn is the delegate's. Revoke ends FUTURE authority
	// and claws back nothing.
	uassert.Equal(t, int64(99_000), CreditOf(delegate1))
	before := balanceOf(delegate1)
	uassert.Equal(t, int64(99_000), claimAs(cur, delegate1))
	uassert.Equal(t, before+99_000, balanceOf(delegate1))
	assertSolvent(t)

	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

func TestReapIsPermissionlessButOnlyForExpired(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	h := Height()
	id := grantAs(cur, owner1, delegate1, 100_000, MinPeriodBlocks, 0, h+200)
	noExpiry := grantAs(cur, owner1, delegate2, 100_000, MinPeriodBlocks, 0, 0)

	// Live: refused, for anyone.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "spendbook: allowance has not expired",
		func() { Reap(cross(cur), id) })
	uassert.False(t, IsExpired(id))

	testing.SkipHeights(200)
	uassert.True(t, IsExpired(id))

	// An expired allowance can authorize nothing, so its own delegate is
	// refused too — and a stranger may clear it.
	testing.SetRealm(testing.NewUserRealm(delegate1))
	uassert.AbortsWithMessage(t, cur, "spendbook: allowance has expired",
		func() { Draw(cross(cur), id, 1) })

	liveBefore := LiveGrants()
	testing.SetRealm(testing.NewUserRealm(mallory))
	Reap(cross(cur), id)
	uassert.Equal(t, liveBefore-1, LiveGrants())
	uassert.Equal(t, int64(1), GrantsOf(owner1))

	// A grant with NO expiry can never be reaped: only its owner ends it.
	uassert.False(t, IsExpired(noExpiry))
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "spendbook: allowance has not expired",
		func() { Reap(cross(cur), noExpiry) })

	revokeAs(cur, owner1, noExpiry)
	withdrawAllAs(cur, owner1)
	assertSolvent(t)
}

// --- fees, surplus, and the absence of an admin ---

func TestWithdrawFeesGoesOnlyToTheFixedCollector(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 500_000, MinPeriodBlocks, 0, 0)
	drawAs(cur, delegate1, id, 500_000)
	uassert.Equal(t, int64(5_000), FeesAccrued())

	// Permissionless, because the destination is a compile-time constant:
	// there is nothing for a caller to steer.
	before := balanceOf(FeeCollector)
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.Equal(t, int64(5_000), WithdrawFees(cross(cur)))
	uassert.Equal(t, before+5_000, balanceOf(FeeCollector))
	uassert.Equal(t, int64(0), FeesAccrued())

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "no fees accrued",
		func() { WithdrawFees(cross(cur)) })
	assertSolvent(t)

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
}

func TestSweepSurplusCannotReachTrackedLiabilities(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 500_000, MinPeriodBlocks, 0, 0)
	drawAs(cur, delegate1, id, 200_000)

	// Nothing out of band yet: the reserve is everything the realm holds,
	// and the primitive ABORTS rather than reporting a transfer of zero.
	uassert.Equal(t, int64(0), Surplus())
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "coinio: no surplus to sweep for ugnot",
		func() { SweepSurplus(cross(cur), Denom) })
	uassert.Equal(t, MinFunding-200_000, PoolOf(owner1))
	uassert.Equal(t, int64(198_000), CreditOf(delegate1))
	uassert.Equal(t, int64(2_000), FeesAccrued())

	// A foreign denom the realm has never held is the same answer: there
	// is nothing to move, so nothing claims to have moved.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "coinio: no surplus to sweep for foocoin",
		func() { SweepSurplus(cross(cur), "foocoin") })

	// Coins arriving outside any entrypoint ARE sweepable, and only those.
	testing.IssueCoins(Address(), ugnot(777))
	uassert.Equal(t, int64(777), Surplus())
	before := balanceOf(FeeCollector)
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.Equal(t, int64(777), SweepSurplus(cross(cur), Denom))
	uassert.Equal(t, before+777, balanceOf(FeeCollector))
	uassert.Equal(t, int64(0), Surplus())

	// Every tracked term survived the sweep untouched.
	uassert.Equal(t, MinFunding-200_000, PoolOf(owner1))
	uassert.Equal(t, int64(198_000), CreditOf(delegate1))
	uassert.Equal(t, int64(2_000), FeesAccrued())
	assertSolvent(t)

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

// TestStraySendIsRejectedOnEveryNonPayableEntrypoint sweeps the whole
// non-payable surface. A coin attached to any of these would otherwise
// become sweepable surplus — silently converting a user's coins into
// operator funds — so aborting and reverting the transfer is the only safe
// answer. The count assertion is deliberate: a table that silently lost
// its rows would otherwise report green.
func TestStraySendIsRejectedOnEveryNonPayableEntrypoint(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	id := grantAs(cur, owner1, delegate1, 100_000, MinPeriodBlocks, 0, 0)

	// No IssueCoins: the envelope is staged but never mirrored into the
	// bank, so a refused call cannot leave surplus behind.
	calls := []func(){
		func() { WithdrawPool(cross(cur), 1) },
		func() { WithdrawPoolAll(cross(cur)) },
		func() { Grant(cross(cur), delegate2, "", 100_000, MinPeriodBlocks, 0, 0) },
		func() { Amend(cross(cur), id, 100_000, 0, 0) },
		func() { Revoke(cross(cur), id) },
		func() { Reap(cross(cur), id) },
		func() { Draw(cross(cur), id, 1_000) },
		func() { Claim(cross(cur)) },
		func() { WithdrawFees(cross(cur)) },
		func() { SweepSurplus(cross(cur), Denom) },
	}
	uassert.Equal(t, 10, len(calls))

	for _, call := range calls {
		testing.SetRealm(testing.NewUserRealm(owner1))
		testing.SetOriginSend(ugnot(1))
		uassert.AbortsWithMessage(t, cur,
			"this entrypoint does not accept coins", call)
		testing.SetOriginSend(nil)
	}

	// The guard runs FIRST in every one of them, which is why even calls
	// that would have failed on their own arguments abort with this
	// message — and why nothing above changed any state.
	uassert.Equal(t, MinFunding, PoolOf(owner1))
	uassert.Equal(t, int64(1), GrantsOf(owner1))
	uassert.Equal(t, int64(100_000), Remaining(id))
	assertSolvent(t)

	revokeAs(cur, owner1, id)
	withdrawAllAs(cur, owner1)
}

// TestDrawableIsTheLesserOfAuthorityAndPool pins the realm's own
// contribution to the view surface. spendbook bounds PERMISSION and says
// so; it never speaks about solvency. Remaining is the authority figure
// and Drawable is the honest one, and conflating them is what would make
// the realm promise what it does not hold.
func TestDrawableIsTheLesserOfAuthorityAndPool(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)

	// Authority below the pool: authority binds.
	small := grantAs(cur, owner1, delegate1, 100_000, MinPeriodBlocks, 0, 0)
	uassert.Equal(t, int64(100_000), Remaining(small))
	uassert.Equal(t, int64(100_000), Drawable(small))

	// Authority above the pool: the pool binds, and Remaining does NOT
	// move — the two views answer different questions.
	big := grantAs(cur, owner1, delegate2, 5*MinFunding, MinPeriodBlocks, 0, 0)
	uassert.Equal(t, 5*MinFunding, Remaining(big))
	uassert.Equal(t, MinFunding, Drawable(big))

	// Two grants, one pool: three grants of 100 against a pool of 100 are
	// all three valid and the first delegate to draw gets the money. The
	// sum of what is drawable deliberately EXCEEDS the pool, because a
	// budget is authority and not a reservation.
	uassert.True(t, Drawable(small)+Drawable(big) > PoolOf(owner1))

	drawAs(cur, delegate1, small, 100_000)
	uassert.Equal(t, MinFunding-100_000, Drawable(big)) // the other shrank

	claimAs(cur, delegate1)
	revokeAs(cur, owner1, small)
	revokeAs(cur, owner1, big)
	withdrawAllAs(cur, owner1)
	tidyFees(cur, t)
}

func TestViewsRefuseUnknownIds(cur realm, t *testing.T) {
	begin()
	// PanicsWithMessage, not AbortsWithMessage, and the distinction is the
	// view/entrypoint one rather than a style choice. revive() catches an
	// ABORT, which is what a panic becomes when it crosses a realm
	// boundary; these six are non-crossing view functions called straight
	// from the test's own frame, so their panic never crosses anything and
	// stays a plain panic. Every other refusal asserted in this file goes
	// through a crossing helper (drawAs, grantAs, …) and is correctly an
	// abort. Getting this backwards does not weaken the assertion — it
	// fails loudly, which is how it was found.
	uassert.PanicsWithMessage(t, cur, "unknown grant id", func() { GrantInfo(999_999) })
	uassert.PanicsWithMessage(t, cur, "unknown grant id", func() { GrantUsage(999_999) })
	uassert.PanicsWithMessage(t, cur, "unknown grant id", func() { GrantLabel(999_999) })
	uassert.PanicsWithMessage(t, cur, "unknown grant id", func() { Remaining(999_999) })
	uassert.PanicsWithMessage(t, cur, "unknown grant id", func() { Drawable(999_999) })
	uassert.PanicsWithMessage(t, cur, "unknown grant id", func() { IsExpired(999_999) })

	// The zero values of the non-panicking views are "nothing", not an
	// error, which is correct for an address that simply has no state.
	uassert.Equal(t, int64(0), PoolOf(mallory))
	uassert.Equal(t, int64(0), CreditOf(mallory))
	uassert.Equal(t, int64(0), GrantsOf(mallory))
}

// --- render ---

func TestRenderPages(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	h := Height()
	testing.SetRealm(testing.NewUserRealm(owner1))
	id := Grant(cross(cur), delegate1, "ops <script>alert(1)</script>",
		100_000, MinPeriodBlocks, 500_000, h+1_000)
	drawAs(cur, delegate1, id, 40_000)

	index := Render("")
	uassert.True(t, strings.Contains(index, "# Budgets"))
	uassert.True(t, strings.Contains(index, "conservation: OK"))
	uassert.True(t, strings.Contains(index, "[live]"))
	uassert.True(t, strings.Contains(index, "#"+itoa(id)))
	// The free-text label reaches markdown only through the ecosystem
	// sanitizer, so the raw tag must not survive into the page.
	uassert.False(t, strings.Contains(index, "<script>"))

	page := Render(itoa(id))
	uassert.True(t, strings.Contains(page, "# Grant #"+itoa(id)))
	uassert.True(t, strings.Contains(page, owner1.String()))
	uassert.True(t, strings.Contains(page, delegate1.String()))
	uassert.True(t, strings.Contains(page, "spent this window: 40000ugnot"))
	uassert.True(t, strings.Contains(page, "authorized by the terms: 60000ugnot"))
	uassert.True(t, strings.Contains(page, "drawable: 60000ugnot"))
	uassert.True(t, strings.Contains(page, "draw fee: 1%"))
	uassert.False(t, strings.Contains(page, "<script>"))

	// The not-funded case is called by its name rather than shown as a
	// bare zero, because "authorized but unfunded" and "nothing
	// authorized" are different situations for a delegate.
	withdrawAllAs(cur, owner1)
	page = Render(itoa(id))
	uassert.True(t, strings.Contains(page, "authorized by the terms: 60000ugnot"))
	uassert.True(t, strings.Contains(page, "drawable: 0ugnot"))
	uassert.True(t, strings.Contains(page, "Authorized but **not funded**"))

	// A queued loosening is disclosed on the page, with the terms that
	// actually govern until the boundary.
	testing.SetRealm(testing.NewUserRealm(owner1))
	uassert.False(t, Amend(cross(cur), id, 900_000, 0, 0))
	page = Render(itoa(id))
	uassert.True(t, strings.Contains(page, "A **looser** amendment is queued"))

	// Expiry, and the keeper prompt that comes with it.
	testing.SkipHeights(1_000)
	page = Render(itoa(id))
	uassert.True(t, strings.Contains(page, "has **expired**"))
	uassert.True(t, strings.Contains(page, "Reap("+itoa(id)+")"))
	index = Render("")
	uassert.True(t, strings.Contains(index, "expired (reapable)"))
	uassert.True(t, strings.Contains(index, "## Keeper work"))

	// Bad paths render a warning rather than panicking a page.
	uassert.True(t, strings.Contains(Render("not-a-number"), "invalid grant id"))
	uassert.True(t, strings.Contains(Render("999999"), "unknown grant id"))

	testing.SetRealm(testing.NewUserRealm(mallory))
	Reap(cross(cur), id)
	claimAs(cur, delegate1)
	tidyFees(cur, t)
	uassert.True(t, strings.Contains(Render(""), "None yet"))
}

func TestRenderIndexIsBounded(cur realm, t *testing.T) {
	begin()
	fundAs(cur, owner1, MinFunding)
	fundAs(cur, owner2, MinFunding)

	ids := []int64{}
	for i := int64(0); i < int64(MaxRenderRows+2); i++ {
		from, to := owner1, delegate1
		if i >= MaxGrantsPerOwner {
			from, to = owner2, delegate2
		}
		ids = append(ids, grantAs(cur, from, to, MinPerPeriod, MinPeriodBlocks, 0, 0))
	}
	uassert.Equal(t, MaxRenderRows+2, len(ids))

	index := Render("")
	uassert.True(t, strings.Contains(index, "Showing the 20 most recent of 22"))
	// Newest first, and the two oldest are off the page.
	uassert.True(t, strings.Contains(index, "#"+itoa(ids[len(ids)-1])))
	uassert.False(t, strings.Contains(index, "#"+itoa(ids[0])+"]"))

	for i, id := range ids {
		from := owner1
		if int64(i) >= MaxGrantsPerOwner {
			from = owner2
		}
		revokeAs(cur, from, id)
	}
	withdrawAllAs(cur, owner1)
	withdrawAllAs(cur, owner2)
	assertSolvent(t)
}

// --- the realm's own arithmetic ---

func TestBpsRendersExactly(t *testing.T) {
	uassert.Equal(t, "1%", bps(100))
	uassert.Equal(t, "5%", bps(500))
	uassert.Equal(t, "0%", bps(0))
	uassert.Equal(t, "0.5%", bps(50))
	uassert.Equal(t, "0.05%", bps(5))
	uassert.Equal(t, "2.25%", bps(225))
	uassert.Equal(t, "100%", bps(10_000))
}

func TestPadIDOrdersNumerically(t *testing.T) {
	uassert.True(t, padID(2) > padID(1))
	uassert.True(t, padID(10) > padID(9))
	uassert.True(t, padID(100) > padID(99))
	uassert.Equal(t, 20, len(padID(1)))
	uassert.Equal(t, 20, len(padID(1_000_000)))
}

func TestCheckedAddRefusesOverflow(t *testing.T) {
	const max = int64(1<<63 - 1)
	sum, ok := checkedAdd(2, 3)
	uassert.True(t, ok)
	uassert.Equal(t, int64(5), sum)

	_, ok = checkedAdd(max, 1)
	uassert.False(t, ok)
	_, ok = checkedAdd(max-1, 2)
	uassert.False(t, ok)
	sum, ok = checkedAdd(max-1, 1)
	uassert.True(t, ok)
	uassert.Equal(t, max, sum)
}

// --- helpers used by the cases above ---

// pendingOf unpacks PendingTerms without the four-value call site noise.
func pendingOf(id int64) (perPeriod, total int64, pending bool) {
	p, tot, _, has := PendingTerms(id)
	return p, tot, has
}

// tidyFees drains the fee pot between cases so each test's fee
// assertions are absolute rather than cumulative. It is a test fixture,
// not a privileged path: WithdrawFees is permissionless and its
// destination is a compile-time constant, so there is nothing here a real
// caller could not also do.
func tidyFees(cur realm, t *testing.T) {
	if FeesAccrued() == 0 {
		return
	}
	testing.SetRealm(testing.NewUserRealm(mallory))
	WithdrawFees(cross(cur))
	uassert.Equal(t, int64(0), FeesAccrued())
}

// TestRenderShowsGoverningTermsPastAnUnobservedBoundary pins the audit
// 2026-11-04 N1 repair. A queued loosening GOVERNS enforcement from the
// first boundary after it was queued -- spendbook's at() applies Pending
// whenever the window has rolled -- but the stored record still holds
// the old Terms until the next write. The grant page used to print the
// old per-window cap with a note claiming "the terms above are what
// govern": risk-understatement to the owner, on the same page whose
// "authorized by the terms" figure already used the pending cap. The
// page must derive its terms exactly as the gate does.
func TestRenderShowsGoverningTermsPastAnUnobservedBoundary(cur realm, t *testing.T) {
	ownr := testutils.TestAddress("n1-owner")
	spndr := testutils.TestAddress("n1-spender")
	fundAs(cur, ownr, 2_000_000)
	id := grantAs(cur, ownr, spndr, 1_000, MinPeriodBlocks, 0, 0)

	// Queue a loosening: raised per-window cap. It must NOT govern yet.
	testing.SetRealm(testing.NewUserRealm(ownr))
	applied := Amend(cross(cur), id, 2_000, 0, 0)
	uassert.False(t, applied) // queued, not applied
	page := Render(itoa(id))
	if !strings.Contains(page, "per-window cap: 1000ugnot") ||
		!strings.Contains(page, "Until then the terms above are what govern") {
		t.Fatalf("pre-boundary page wrong:\n%s", page)
	}

	// Cross the boundary with NO intervening write. The pending terms
	// now govern enforcement (at() applies them); the page must say so.
	testing.SkipHeights(MinPeriodBlocks)
	page = Render(itoa(id))
	if !strings.Contains(page, "per-window cap: 2000ugnot") {
		t.Fatalf("page still prints the superseded cap past the boundary:\n%s", page)
	}
	if strings.Contains(page, "Until then the terms above are what govern") {
		t.Fatalf("page still claims the stored terms govern past the boundary")
	}
}
