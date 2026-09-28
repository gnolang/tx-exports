package vesting

import (
	"strings"
	"testing"

	"chain"
	"chain/banker"
	"chain/runtime"

	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/duebook"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	testAdmin = testutils.TestAddress("vestadmin")
	funder1   = testutils.TestAddress("vfunder1")
	funder2   = testutils.TestAddress("vfunder2")
	bene1     = testutils.TestAddress("vbene1")
	bene2     = testutils.TestAddress("vbene2")
	mallory   = testutils.TestAddress("vmallory")
	stranger  = testutils.TestAddress("vstranger")
)

// HARNESS NOTES, carried from the duebook_demo and grants suites and
// re-verified here:
//
//   - testing.SetRealm records the override per FRAME INDEX. A helper that
//     stages a caller and RETURNS leaves the test frame untouched, so the
//     previous staging silently wins and every caller looks like the same
//     account — which hides exactly the authorization bugs these tests
//     exist to find. Every caller below is therefore staged INLINE in the
//     frame that makes the call. The staging helpers (fundAs, callAs) are
//     safe only because they make their call from inside their own frame.
//
//   - Realm globals PERSIST across tests in the test VM, while banker
//     state resets per test. The monetary invariant is therefore asserted
//     in DELTA form after re-seeding carried liabilities (begin()).
//
//   - A panic caught by uassert does NOT roll back realm globals here,
//     whereas on-chain it aborts and reverts the whole transaction. Every
//     abort asserted below happens strictly BEFORE this realm writes any
//     state, so the distinction never bites. The one path where it could —
//     a book.Schedule failure partway through Fund's loop — is unreachable
//     because Fund pre-checks capacity, and is not asserted here.
//
//   - Tests must not assume a fixed starting height, schedule id, or
//     tranche id. They read all three and reason in deltas.
func init() {
	admin = testAdmin
	feeRecipient = testAdmin
	self = chain.PackageAddress("gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/vesting")
}

// --- harness ---

type baseline struct{ held, escrow, users, fees int64 }

func begin() baseline {
	// Disarm any OriginSend a previous test left staged. The envelope is
	// process-global, not per-frame, and a leftover one makes the first
	// non-Fund entrypoint of this test abort in rejectStraySend — which
	// looks exactly like the guard working and is really the harness
	// leaking. Each test opens with an empty envelope, as a fresh tx does.
	testing.SetOriginSend(nil)
	if l := Liabilities(); l > 0 {
		testing.IssueCoins(Address(), ugnot(l))
	}
	return baseline{held: Held(), escrow: EscrowTotal(), users: UsersTotal(), fees: FeesAccrued()}
}

// conserved asserts ΔH == ΔE + ΔU + ΔF + extraSurplus.
func (b baseline) conserved(t *testing.T, extraSurplus int64) {
	t.Helper()
	dH := Held() - b.held
	dE := EscrowTotal() - b.escrow
	dU := UsersTotal() - b.users
	dF := FeesAccrued() - b.fees
	if dH != dE+dU+dF+extraSurplus {
		t.Fatalf("conservation violated: dH=%d dE=%d dU=%d dF=%d dS=%d", dH, dE, dU, dF, extraSurplus)
	}
	// NOT a test — an identity. Liabilities() is DEFINED as escrowTotal +
	// ledger.Liabilities(), and ledger.Liabilities() as usersTotal +
	// feesAccrued, so both sides are the same expression and this can only
	// fail on integer overflow. Kept deliberately, as an overflow tripwire
	// and as executable documentation of the definition; the real
	// conservation check is the dH comparison above, which is against the
	// banker's actual balance and can genuinely fail.
	if Liabilities() != EscrowTotal()+UsersTotal()+FeesAccrued() {
		t.Fatalf("Liabilities() = %d, want E+U+F", Liabilities())
	}
}

// pendingSum recomputes the sum of amounts over pending tranches — the
// application invariant E == Σ pending.
func pendingSum() int64 {
	sum := int64(0)
	tranches.Iterate("", "", func(_ string, v any) bool {
		if t := v.(*tranche); t.status == StatusPending {
			sum += t.amount
		}
		return false
	})
	return sum
}

func pendingCount() int {
	n := 0
	tranches.Iterate("", "", func(_ string, v any) bool {
		if v.(*tranche).status == StatusPending {
			n++
		}
		return false
	})
	return n
}

// appInvariant asserts BOTH stores agree: escrowTotal tracks the pending
// tranches, and duebook holds exactly one open deferral per pending
// tranche. The second half is the cross-store check that matters most —
// a tranche this realm thinks is pending but duebook has consumed would
// be unreleasable escrow, and the reverse would be a double-spend.
func appInvariant(t *testing.T) {
	t.Helper()
	if got := pendingSum(); got != EscrowTotal() {
		t.Fatalf("app invariant violated: escrowTotal=%d, sum pending=%d", EscrowTotal(), got)
	}
	if got := book.OpenCount(); got != pendingCount() {
		t.Fatalf("store divergence: duebook open=%d, pending tranches=%d", got, pendingCount())
	}
	assertOpenCounts(t)
	// Per-schedule bookkeeping must add up to the schedule total.
	for id := int64(1); id <= NumSchedules(); id++ {
		s := mustSchedule(id)
		pend := int64(0)
		for _, did := range s.trancheIDs {
			if tranches.Get(padU(did)).(*tranche).status == StatusPending {
				pend += tranches.Get(padU(did)).(*tranche).amount
			}
		}
		if pend+s.releasedGross+s.revokedTotal != s.total {
			t.Fatalf("schedule %d: pending=%d + released=%d + revoked=%d != total=%d",
				id, pend, s.releasedGross, s.revokedTotal, s.total)
		}
	}
}

// assertOpenCounts recomputes every funder's pending-tranche count from the
// tranche records and compares it to the openByFunder counter. This is the
// THIRD cross-store check, and it earns its place: the counter gates Fund,
// so a counter that drifts high locks an honest funder out of a realm that
// has room, and one that drifts low silently defeats the per-funder cap.
// It also asserts the zero-entry removal, because a tree that accumulates a
// dead 0 per address that ever funded anything is an unbounded growth path.
func assertOpenCounts(t *testing.T) {
	t.Helper()

	want := map[string]int64{}
	tranches.Iterate("", "", func(_ string, v any) bool {
		tr := v.(*tranche)
		if tr.status == StatusPending {
			want[mustSchedule(tr.scheduleID).funder.String()]++
		}
		return false
	})

	got := map[string]int64{}
	total := int64(0)
	openByFunder.Iterate("", "", func(k string, v any) bool {
		n := v.(int64)
		if n == 0 {
			t.Fatalf("openByFunder holds a zero entry for %s; it must be removed at zero", k)
		}
		got[k] = n
		total += n
		return false
	})

	if len(got) != len(want) {
		t.Fatalf("openByFunder tracks %d funder(s), recomputed %d", len(got), len(want))
	}
	for k, w := range want {
		if got[k] != w {
			t.Fatalf("funder %s: counter says %d, tranche records say %d", k, got[k], w)
		}
	}
	if total != int64(pendingCount()) {
		t.Fatalf("openByFunder totals %d, pending tranches %d", total, pendingCount())
	}
	if got := FundersWithOpenTranches(); got != len(want) {
		t.Fatalf("FundersWithOpenTranches()=%d, recomputed %d", got, len(want))
	}
}

func coinsOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, Denom)
}

func ugnot(n int64) chain.Coins {
	return chain.NewCoins(chain.NewCoin(Denom, n))
}

// fundAs performs a chain-faithful funded Fund. Must be called from the
// test function's own frame.
//
// The OriginSend envelope is NOT per-frame: whatever was last staged stays
// visible to every later call in the process. Fund is the one entrypoint
// that accepts coins, so leaving the envelope armed makes the very next
// Release/Revoke abort in rejectStraySend instead of reaching the logic
// under test. Clear it on the way out — a real transaction ends here.
func fundAs(cur realm, from, beneficiary address, total int64, title, memo, spec string, revocable bool) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginCaller(from)
	testing.SetOriginSend(ugnot(total))
	testing.IssueCoins(Address(), ugnot(total))
	id := Fund(cross(cur), beneficiary, title, memo, spec, revocable, MaxFeeBps)
	testing.SetOriginSend(nil)
	return id
}

// trancheIDsOf returns a schedule's tranche ids as int64, in order.
func trancheIDsOf(id int64) []int64 {
	s := mustSchedule(id)
	out := []int64{}
	for _, did := range s.trancheIDs {
		out = append(out, int64(did))
	}
	return out
}

// --- tests ---

func TestInitialConfig(t *testing.T) {
	if Admin() != testAdmin || FeeRecipient() != testAdmin {
		t.Fatal("seeded roles mismatch")
	}
	var zero address
	if PendingAdmin() != zero {
		t.Fatal("pendingAdmin should start zero")
	}
	if Address() == zero {
		t.Fatal("realm address is zero")
	}
	// Reference duebook's own constant, NOT a hardcoded 10000. With the
	// literal, both operands were compile-time constants and the branch was
	// dead — it could not fail even if duebook were redeployed with a lower
	// limit, and duebook.MustNew would then panic at realm init instead,
	// turning a caught test failure into a deploy-time abort.
	if MaxOpenTranches > duebook.MaxOpenLimit {
		t.Fatalf("MaxOpenTranches %d exceeds duebook.MaxOpenLimit %d",
			MaxOpenTranches, duebook.MaxOpenLimit)
	}
	if MaxOpenPerFunder > MaxOpenTranches {
		t.Fatalf("MaxOpenPerFunder %d exceeds the whole-realm cap %d",
			MaxOpenPerFunder, MaxOpenTranches)
	}
	if book.MinDelay() != MinDelayBlocks || book.MaxDelay() != MaxDelayBlocks {
		t.Fatal("book bounds do not match the declared constants")
	}
}

func TestFundHappyPath(cur realm, t *testing.T) {
	b := begin()
	h := runtime.ChainHeight()

	id := fundAs(cur, funder1, bene1, 1000, "engineer grant", "a memo", "10:200,20:300,30:500", true)

	funder, beneficiary, title, total, snapBps, revocable,
		createdAt, numTranches, pending, releasedGross, revokedTotal := ScheduleInfo(id)
	if funder != funder1 || beneficiary != bene1 || title != "engineer grant" {
		t.Fatalf("identity fields wrong: %v %v %q", funder, beneficiary, title)
	}
	if total != 1000 || snapBps != 0 || !revocable {
		t.Fatalf("terms wrong: total=%d bps=%d revocable=%v", total, snapBps, revocable)
	}
	if createdAt != h || numTranches != 3 || pending != 3 || releasedGross != 0 || revokedTotal != 0 {
		t.Fatalf("bookkeeping wrong: createdAt=%d n=%d pending=%d rel=%d rev=%d",
			createdAt, numTranches, pending, releasedGross, revokedTotal)
	}
	if Memo(id) != "a memo" {
		t.Fatal("memo mismatch")
	}

	// Tranche records carry the right amounts and absolute due heights.
	ids := trancheIDsOf(id)
	wantAmounts := []int64{200, 300, 500}
	wantDue := []int64{h + 10, h + 20, h + 30}
	for i, tid := range ids {
		sID, seq, amount, dueAt, status, settledAt := TrancheInfo(tid)
		if sID != id || seq != int64(i+1) || amount != wantAmounts[i] ||
			dueAt != wantDue[i] || status != StatusPending || settledAt != 0 {
			t.Fatalf("tranche %d wrong: sched=%d seq=%d amount=%d due=%d status=%s settled=%d",
				tid, sID, seq, amount, dueAt, status, settledAt)
		}
	}

	appInvariant(t)
	b.conserved(t, 0)
}

func TestFundRejectsEnvelope(cur realm, t *testing.T) {
	b := begin()

	// Not a direct EOA call (coinio.Receive guard).
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/attacker"))
	testing.SetOriginSend(ugnot(100))
	uassert.AbortsContains(t, cur, "direct EOA call", func() {
		Fund(cross(cur), bene1, "evil", "", "10:100", false, MaxFeeBps)
	})

	// No coins at all.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "exactly one coin type", func() {
		Fund(cross(cur), bene1, "no coins", "", "10:100", false, MaxFeeBps)
	})

	// Wrong denomination.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("foocoin", 100)))
	uassert.AbortsContains(t, cur, "exactly one coin type", func() {
		Fund(cross(cur), bene1, "wrong denom", "", "10:100", false, MaxFeeBps)
	})

	appInvariant(t)
	b.conserved(t, 0)
}

func TestFundRejectsTerms(cur realm, t *testing.T) {
	b := begin()
	var zero address

	// Each case stages inline, because SetRealm is per-frame.
	cases := []struct {
		name, want  string
		beneficiary address
		title, memo string
		spec        string
		sent        int64
	}{
		{"zero beneficiary", "empty beneficiary", zero, "t", "", "10:100", 100},
		// A balance credited to the realm's own address is claimable by
		// nobody and still counted in Liabilities(), so it is stranded
		// AND it shrinks SweepDenom's reach. Released by any third
		// party, so the funder cannot undo it.
		{"self beneficiary", "must not be this realm's own address", self, "t", "", "10:100", 100},
		{"empty title", "title must be", bene1, "", "", "10:100", 100},
		{"long title", "title must be", bene1, strings.Repeat("a", MaxTitleLen+1), "", "10:100", 100},
		{"bad title charset", "letters, digits", bene1, "bad!title", "", "10:100", 100},
		{"long memo", "memo exceeds", bene1, "t", strings.Repeat("m", MaxMemoLen+1), "10:100", 100},
		{"empty spec", "at least one tranche", bene1, "t", "", "", 100},
		{"long spec", "spec exceeds", bene1, "t", "", strings.Repeat("9", MaxSpecLen+1), 100},
		{"missing colon", "expected", bene1, "t", "", "10-100", 100},
		{"delay not integer", "delay is not an integer", bene1, "t", "", "ten:100", 100},
		{"amount not integer", "amount is not an integer", bene1, "t", "", "10:lots", 100},
		{"delay zero", "outside", bene1, "t", "", "0:100", 100},
		{"delay too large", "outside", bene1, "t", "", "100000001:100", 100},
		{"delays equal", "strictly increasing", bene1, "t", "", "10:50,10:50", 100},
		{"delays decreasing", "strictly increasing", bene1, "t", "", "20:50,10:50", 100},
		{"zero amount", "amount must be positive", bene1, "t", "", "10:0", 100},
		{"negative amount", "amount must be positive", bene1, "t", "", "10:-5", 100},
		{"underfunded", "they must be equal", bene1, "t", "", "10:200", 100},
		{"overfunded", "they must be equal", bene1, "t", "", "10:50", 100},
	}

	// A cross-call abort is NOT catchable with recover() in the calling
	// realm — that is what uassert.AbortsContains is for. Staging stays in
	// this frame, immediately before each call.
	for _, c := range cases {
		spec := c.spec
		ben := c.beneficiary
		title := c.title
		memo := c.memo

		testing.SetRealm(testing.NewUserRealm(mallory))
		testing.SetOriginCaller(mallory)
		testing.SetOriginSend(ugnot(c.sent))
		uassert.AbortsContains(t, cur, c.want, func() {
			Fund(cross(cur), ben, title, memo, spec, false, MaxFeeBps)
		}, c.name)
	}

	// Too many tranches: MaxTranches+1 entries with increasing delays.
	parts := []string{}
	for i := 1; i <= MaxTranches+1; i++ {
		parts = append(parts, itoa(int64(i))+":1")
	}
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(ugnot(int64(MaxTranches + 1)))
	uassert.AbortsContains(t, cur, "at most "+itoa(MaxTranches)+" tranches", func() {
		Fund(cross(cur), bene1, "many", "", strings.Join(parts, ","), false, MaxFeeBps)
	})

	appInvariant(t)
	b.conserved(t, 0)
}

func TestReleaseBeforeDueAborts(cur realm, t *testing.T) {
	b := begin()
	id := fundAs(cur, funder1, bene1, 100, "not yet", "", "5:100", false)
	tid := trancheIDsOf(id)[0]

	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginCaller(stranger)
	uassert.AbortsContains(t, cur, "not due yet", func() { Release(cross(cur), tid) })

	// Nothing moved.
	if BalanceOf(bene1) != 0 {
		t.Fatal("beneficiary credited before the due height")
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// TestReleaseIsPermissionlessAndPaysTheBeneficiary is the central
// authorization property: a stranger may trigger the release, and doing so
// credits the RECORDED beneficiary, never the caller.
func TestReleaseIsPermissionlessAndPaysTheBeneficiary(cur realm, t *testing.T) {
	b := begin()
	id := fundAs(cur, funder1, bene1, 400, "payable", "", "1:400", false)
	tid := trancheIDsOf(id)[0]

	beneBefore := BalanceOf(bene1)
	malloryBefore := BalanceOf(mallory)
	testing.SkipHeights(1)

	// Mallory, an unrelated account, triggers the release.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	Release(cross(cur), tid)

	if got := BalanceOf(bene1) - beneBefore; got != 400 {
		t.Fatalf("beneficiary credited %d, want 400", got)
	}
	if got := BalanceOf(mallory) - malloryBefore; got != 0 {
		t.Fatalf("the caller was credited %d; release must never pay the caller", got)
	}
	_, _, _, _, status, settledAt := TrancheInfo(tid)
	if status != StatusReleased || settledAt == 0 {
		t.Fatalf("tranche not marked released: status=%s settledAt=%d", status, settledAt)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// TestDoubleReleaseIsImpossible is the property duebook exists to provide.
// The second attempt must fail because the deferral no longer exists — not
// because this realm re-checked a status flag.
func TestDoubleReleaseIsImpossible(cur realm, t *testing.T) {
	b := begin()
	id := fundAs(cur, funder1, bene1, 700, "once only", "", "1:700", false)
	tid := trancheIDsOf(id)[0]
	testing.SkipHeights(1)

	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	Release(cross(cur), tid)
	after := BalanceOf(bene1)

	// Second attempt, same transaction-equivalent frame and a different
	// caller: duebook has consumed the ID and can never return it again.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	uassert.AbortsContains(t, cur, "no such open deferral", func() { Release(cross(cur), tid) })

	// And a third, from the beneficiary.
	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	uassert.AbortsContains(t, cur, "no such open deferral", func() { Release(cross(cur), tid) })

	if BalanceOf(bene1) != after {
		t.Fatal("a repeat release changed the balance")
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// TestVestedTrancheCannotBeRevoked is this realm's own check, not
// duebook's: duebook.Cancel would consume a due-but-unclaimed deferral
// happily. Without the refusal a funder could front-run the beneficiary.
func TestVestedTrancheCannotBeRevoked(cur realm, t *testing.T) {
	b := begin()
	id := fundAs(cur, funder1, bene1, 300, "vested now", "", "1:300", true)
	tid := trancheIDsOf(id)[0]

	testing.SkipHeights(1) // now == dueAt: vested

	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	uassert.AbortsContains(t, cur, "can never be revoked", func() { Revoke(cross(cur), tid) })

	// Still releasable to the beneficiary afterwards.
	before := BalanceOf(bene1)
	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginCaller(stranger)
	Release(cross(cur), tid)
	if got := BalanceOf(bene1) - before; got != 300 {
		t.Fatalf("beneficiary credited %d after a refused revocation, want 300", got)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

func TestRevokeAuthorization(cur realm, t *testing.T) {
	b := begin()
	rev := fundAs(cur, funder1, bene1, 500, "revocable one", "", "100:500", true)
	irr := fundAs(cur, funder2, bene2, 600, "irrevocable one", "", "100:600", false)
	revTID := trancheIDsOf(rev)[0]
	irrTID := trancheIDsOf(irr)[0]

	// A stranger may not revoke.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	uassert.AbortsContains(t, cur, "only the funder may revoke", func() { Revoke(cross(cur), revTID) })

	// Nor may the beneficiary.
	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	uassert.AbortsContains(t, cur, "only the funder may revoke", func() { Revoke(cross(cur), revTID) })

	// Nor the OTHER schedule's funder.
	testing.SetRealm(testing.NewUserRealm(funder2))
	testing.SetOriginCaller(funder2)
	uassert.AbortsContains(t, cur, "only the funder may revoke", func() { Revoke(cross(cur), revTID) })

	// An irrevocable schedule refuses even its own funder.
	testing.SetRealm(testing.NewUserRealm(funder2))
	testing.SetOriginCaller(funder2)
	uassert.AbortsContains(t, cur, "is irrevocable", func() { Revoke(cross(cur), irrTID) })

	// RevokeAll carries the same two checks.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	uassert.AbortsContains(t, cur, "only the funder may revoke", func() { RevokeAll(cross(cur), rev) })
	testing.SetRealm(testing.NewUserRealm(funder2))
	testing.SetOriginCaller(funder2)
	uassert.AbortsContains(t, cur, "is irrevocable", func() { RevokeAll(cross(cur), irr) })

	appInvariant(t)
	b.conserved(t, 0)
}

func TestRevokeRefundsFunderFeeFree(cur realm, t *testing.T) {
	// A non-zero fee must NOT be charged on a revocation.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 500)

	b := begin()
	id := fundAs(cur, funder1, bene1, 800, "clawback", "", "1000:800", true)
	tid := trancheIDsOf(id)[0]

	funderBefore := BalanceOf(funder1)
	feesBefore := FeesAccrued()

	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	Revoke(cross(cur), tid)

	if got := BalanceOf(funder1) - funderBefore; got != 800 {
		t.Fatalf("funder refunded %d, want the full 800 fee-free", got)
	}
	if FeesAccrued() != feesBefore {
		t.Fatalf("a revocation accrued a fee: %d -> %d", feesBefore, FeesAccrued())
	}
	_, _, _, _, status, settledAt := TrancheInfo(tid)
	if status != StatusRevoked || settledAt == 0 {
		t.Fatalf("tranche not marked revoked: %s %d", status, settledAt)
	}

	// A revoked tranche can never be released: duebook consumed the ID.
	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	uassert.AbortsContains(t, cur, "no such open deferral", func() { Release(cross(cur), tid) })

	appInvariant(t)
	b.conserved(t, 0)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 0)
}

func TestRevokeAllSkipsVestedAndSettled(cur realm, t *testing.T) {
	b := begin()
	// Tranche 1 due at +1, the rest far out.
	id := fundAs(cur, funder1, bene1, 1000, "mixed", "", "1:100,500:200,600:300,700:400", true)
	ids := trancheIDsOf(id)

	testing.SkipHeights(1) // tranche 1 vests

	// Release tranche 1 so it is settled, not merely vested.
	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginCaller(stranger)
	Release(cross(cur), ids[0])

	funderBefore := BalanceOf(funder1)
	beneBefore := BalanceOf(bene1)
	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	RevokeAll(cross(cur), id)

	// The three unvested tranches came back; the released one did not.
	if got := BalanceOf(funder1) - funderBefore; got != 900 {
		t.Fatalf("funder refunded %d, want 900 (1000 less the released 100)", got)
	}
	// Assert the DELTA, not the absolute. BalanceOf(bene1) is cumulative
	// across the whole suite and is already far above 100 by this point, so
	// a `< 100` check could not fail however badly RevokeAll behaved. What
	// must hold is that RevokeAll moved nothing out of the beneficiary.
	if got := BalanceOf(bene1) - beneBefore; got != 0 {
		t.Fatalf("RevokeAll changed the beneficiary balance by %d, want 0", got)
	}
	_, _, _, _, st0, _ := TrancheInfo(ids[0])
	if st0 != StatusReleased {
		t.Fatalf("released tranche was altered by RevokeAll: %s", st0)
	}
	for _, tid := range ids[1:] {
		_, _, _, _, st, _ := TrancheInfo(tid)
		if st != StatusRevoked {
			t.Fatalf("tranche %d status %s, want revoked", tid, st)
		}
	}

	// A second RevokeAll has nothing left to do and must say so rather
	// than report a silent success.
	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	uassert.AbortsContains(t, cur, "no revocable tranches", func() { RevokeAll(cross(cur), id) })

	appInvariant(t)
	b.conserved(t, 0)
}

func TestWithdrawPaysOutAndDebitsFirst(cur realm, t *testing.T) {
	b := begin()
	id := fundAs(cur, funder1, bene1, 250, "payout test", "", "1:250", false)
	tid := trancheIDsOf(id)[0]
	testing.SkipHeights(1)

	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	Release(cross(cur), tid)

	claimable := BalanceOf(bene1)
	if claimable < 250 {
		t.Fatalf("claimable %d, want at least 250", claimable)
	}
	coinsBefore := coinsOf(bene1)

	// Partial withdrawal.
	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	testing.SetOriginSend(nil)
	Withdraw(cross(cur), 100)
	if got := coinsOf(bene1) - coinsBefore; got != 100 {
		t.Fatalf("received %d coins, want 100", got)
	}
	if BalanceOf(bene1) != claimable-100 {
		t.Fatalf("ledger not debited: %d", BalanceOf(bene1))
	}

	// Over-withdrawal is refused.
	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	uassert.AbortsContains(t, cur, "insufficient balance", func() { Withdraw(cross(cur), claimable) })

	// The rest.
	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	WithdrawAll(cross(cur))
	if BalanceOf(bene1) != 0 {
		t.Fatalf("balance after WithdrawAll = %d", BalanceOf(bene1))
	}

	// Nothing left to withdraw: feeledger returns (0, nil) for an empty
	// account, so this realm's own guard is what turns that into an abort.
	testing.SetRealm(testing.NewUserRealm(bene1))
	testing.SetOriginCaller(bene1)
	uassert.AbortsContains(t, cur, "nothing to withdraw", func() { WithdrawAll(cross(cur)) })

	// A stranger with no balance cannot withdraw.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	uassert.AbortsContains(t, cur, "insufficient balance", func() { Withdraw(cross(cur), 1) })

	// Every withdrawal moved H and U by the same amount, so the identity
	// holds with no surplus term: dH == dE + dU + dF.
	appInvariant(t)
	b.conserved(t, 0)
}

// TestFeeSnapshotAndCeiling covers both halves of the fee race: a fee
// change never reaches an already-funded schedule, and a fee raise
// sequenced ahead of a Fund is refused rather than silently applied.
func TestFeeSnapshotAndCeiling(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 200)

	b := begin()
	id := fundAs(cur, funder1, bene1, 1000, "snapshotted", "", "1:1000", false)
	_, _, _, _, snapBps, _, _, _, _, _, _ := ScheduleInfo(id)
	if snapBps != 200 {
		t.Fatalf("snapshot bps = %d, want 200", snapBps)
	}

	// Admin raises the fee AFTER funding; the schedule keeps 200.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 1000)

	tid := trancheIDsOf(id)[0]
	testing.SkipHeights(1)
	beneBefore := BalanceOf(bene1)
	feesBefore := FeesAccrued()

	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginCaller(stranger)
	Release(cross(cur), tid)

	// 200 bps of 1000 == 20, charged at the SNAPSHOT, not the live 1000 bps.
	if got := FeesAccrued() - feesBefore; got != 20 {
		t.Fatalf("fee charged = %d, want 20 (the snapshot)", got)
	}
	if got := BalanceOf(bene1) - beneBefore; got != 980 {
		t.Fatalf("beneficiary credited %d, want 980", got)
	}

	// The creation-time race: the live fee is now 1000, so a caller who
	// signs for at most 200 must be refused.
	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	testing.SetOriginSend(ugnot(100))
	uassert.AbortsContains(t, cur, "exceeds the caller's maximum", func() {
		Fund(cross(cur), bene1, "raced", "", "10:100", false, 200)
	})
	testing.SetOriginSend(nil) // disarm; the envelope is process-global

	appInvariant(t)
	b.conserved(t, 0)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 0)
}

func TestFeeWithdrawalAuthorization(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 1000)

	b := begin()
	id := fundAs(cur, funder1, bene1, 1000, "fees", "", "1:1000", false)
	tid := trancheIDsOf(id)[0]
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginCaller(stranger)
	Release(cross(cur), tid)

	if FeesAccrued() == 0 {
		t.Fatal("no fee accrued at 1000 bps")
	}

	// A non-recipient cannot withdraw fees or sweep.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	uassert.AbortsContains(t, cur, "only the fee recipient", func() { WithdrawFees(cross(cur)) })
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	uassert.AbortsContains(t, cur, "only the fee recipient", func() { SweepDenom(cross(cur), Denom) })

	pot := FeesAccrued()
	coinsBefore := coinsOf(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	WithdrawFees(cross(cur))
	if got := coinsOf(testAdmin) - coinsBefore; got != pot {
		t.Fatalf("fee recipient received %d, want %d", got, pot)
	}
	if FeesAccrued() != 0 {
		t.Fatalf("fee pot not drained: %d", FeesAccrued())
	}

	// Draining twice is refused.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	uassert.AbortsContains(t, cur, "no fees accrued", func() { WithdrawFees(cross(cur)) })

	appInvariant(t)
	// The withdrawal took 120 out of H *and* out of F, so both sides of the
	// identity moved together and there is no surplus term. dF is only -20
	// because 20 of that 120 was accrued by an earlier test and is inside
	// the baseline: F went 20 -> 120 -> 0. Subtracting `pot` here would be
	// double-counting the very transfer dH already records.
	b.conserved(t, 0)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 0)
}

// TestSetFeeRecipientSettlesTheOutgoingRecipient is audit finding Y2: the
// fee pot is a single scalar with no per-recipient accounting, so a bare
// re-point would hand every basis point earned under the old recipient to
// the new one at the admin's sole discretion.
func TestSetFeeRecipientSettlesTheOutgoingRecipient(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 1000)

	b := begin()
	id := fundAs(cur, funder1, bene1, 1000, "settle", "", "1:1000", false)
	tid := trancheIDsOf(id)[0]
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginCaller(stranger)
	Release(cross(cur), tid)

	pot := FeesAccrued()
	if pot == 0 {
		t.Fatal("no fee accrued at 1000 bps")
	}
	oldRecipient := FeeRecipient()
	oldClaimBefore := BalanceOf(oldRecipient)
	newClaimBefore := BalanceOf(bene2)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeRecipient(cross(cur), bene2)

	if FeeRecipient() != bene2 {
		t.Fatalf("recipient is %s, want %s", FeeRecipient(), bene2)
	}
	// The pot moved to the OUTGOING recipient's claimable balance...
	if got := BalanceOf(oldRecipient) - oldClaimBefore; got != pot {
		t.Fatalf("outgoing recipient credited %d, want the whole pot %d", got, pot)
	}
	// ...and F is now empty, so the successor inherits the role, not the
	// earnings. This is the assertion the finding is about.
	if FeesAccrued() != 0 {
		t.Fatalf("fee pot still holds %d after re-pointing", FeesAccrued())
	}
	if got := BalanceOf(bene2) - newClaimBefore; got != 0 {
		t.Fatalf("successor was credited %d of the predecessor's earnings, want 0", got)
	}
	// The successor has no pot to drain.
	testing.SetRealm(testing.NewUserRealm(bene2))
	testing.SetOriginCaller(bene2)
	uassert.AbortsContains(t, cur, "no fees accrued", func() { WithdrawFees(cross(cur)) })

	// No coins moved: F simply became U. Conservation is untouched.
	appInvariant(t)
	b.conserved(t, 0)

	// A re-point to the SAME address is a no-op and must not churn the pot.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeRecipient(cross(cur), bene2)
	if FeesAccrued() != 0 {
		t.Fatal("self re-point disturbed the pot")
	}

	// Restore the suite's baseline roles and fee.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeRecipient(cross(cur), testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 0)
}

// TestPerFunderCapIsEnforcedAndFreed is audit finding Y1: MaxOpenTranches is
// a whole-realm cap, and without a per-funder bound one account could fill
// it for ~nothing and then reclaim every coin fee-free with RevokeAll.
//
// It also closes the coverage gap the audit named: before this, NO test
// exercised a capacity check at all. The whole-realm cap itself stays
// untested on purpose — reaching it needs 5000 tranches, and the per-funder
// cap is now the binding one for any single account, which is the point.
func TestPerFunderCapIsEnforcedAndFreed(cur realm, t *testing.T) {
	b := begin()

	// onesSpec builds n tranches of 1ugnot with strictly increasing delays.
	// n == MaxTranches is the largest schedule a single Fund can create.
	onesSpec := func(n int64) string {
		parts := []string{}
		for i := int64(1); i <= n; i++ {
			parts = append(parts, itoa(i)+":1")
		}
		return strings.Join(parts, ",")
	}

	// Realm globals persist across tests, so funder2 may already hold pending
	// tranches and the headroom need not divide evenly by MaxTranches. Fill
	// with full schedules and top off with the remainder rather than assert an
	// arithmetic coincidence: an earlier draft asserted room%MaxTranches==0 and
	// failed at room=255.
	start := OpenTranchesOfFunder(funder2)
	room := int64(MaxOpenPerFunder) - start
	if room <= 0 {
		t.Fatalf("funder2 starts at %d pending, already at the cap %d", start, MaxOpenPerFunder)
	}

	ids := []int64{}
	sizes := []int64{}
	for left := room; left > 0; {
		n := int64(MaxTranches)
		if left < n {
			n = left
		}
		ids = append(ids, fundAs(cur, funder2, bene2, n, "fill", "", onesSpec(n), true))
		sizes = append(sizes, n)
		left -= n
	}
	if got := OpenTranchesOfFunder(funder2); got != int64(MaxOpenPerFunder) {
		t.Fatalf("funder2 holds %d pending, want the cap %d", got, MaxOpenPerFunder)
	}

	// One more tranche — a single one — must be refused.
	testing.SetRealm(testing.NewUserRealm(funder2))
	testing.SetOriginCaller(funder2)
	testing.SetOriginSend(ugnot(1))
	testing.IssueCoins(Address(), ugnot(1))
	uassert.AbortsContains(t, cur, "funder tranche capacity reached", func() {
		Fund(cross(cur), bene2, "one too many", "", "1:1", false, MaxFeeBps)
	})
	testing.SetOriginSend(nil)

	// The 1ugnot issued for that rejected Fund never entered the escrow, so
	// it is surplus now. Account for it explicitly rather than let it hide
	// inside a tolerance.
	surplus := int64(1)

	// The cap is PER FUNDER, not global: a different funder is unaffected
	// even though funder2 is at its own ceiling.
	otherID := fundAs(cur, funder1, bene1, 5, "unaffected", "", "1:5", true)
	if OpenTranchesOfFunder(funder1) < 1 {
		t.Fatal("funder1 was blocked by funder2's cap")
	}

	// Releasing or revoking frees the slot again. Revoke one whole schedule
	// and confirm funder2 gets back exactly that schedule's worth of headroom.
	testing.SetRealm(testing.NewUserRealm(funder2))
	testing.SetOriginCaller(funder2)
	RevokeAll(cross(cur), ids[0])
	if got := OpenTranchesOfFunder(funder2); got != int64(MaxOpenPerFunder)-sizes[0] {
		t.Fatalf("after RevokeAll funder2 holds %d, want %d",
			got, int64(MaxOpenPerFunder)-sizes[0])
	}
	// ...and can fund again.
	ids[0] = fundAs(cur, funder2, bene2, sizes[0], "refill", "", onesSpec(sizes[0]), true)
	if got := OpenTranchesOfFunder(funder2); got != int64(MaxOpenPerFunder) {
		t.Fatalf("after refunding funder2 holds %d, want the cap %d", got, MaxOpenPerFunder)
	}

	// Clean up: return funder2 to its starting count so later tests are not
	// funding against a full account, and drop the counter entries to prove
	// the zero-removal path runs.
	for _, id := range ids {
		testing.SetRealm(testing.NewUserRealm(funder2))
		testing.SetOriginCaller(funder2)
		RevokeAll(cross(cur), id)
	}
	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	RevokeAll(cross(cur), otherID)
	if got := OpenTranchesOfFunder(funder2); got != start {
		t.Fatalf("funder2 left with %d pending, want the starting %d", got, start)
	}

	appInvariant(t)
	b.conserved(t, surplus)
}

// TestSweepCannotTouchEscrow is the reserve property: surplus is
// sweepable, escrowed tranches and claimable balances are not.
func TestSweepCannotTouchEscrow(cur realm, t *testing.T) {
	b := begin()
	fundAs(cur, funder1, bene1, 900, "reserved", "", "1000:900", false)

	// Force-send 77 ugnot out of band, then sweep. Only the 77 may move.
	testing.IssueCoins(Address(), ugnot(77))
	if got := Surplus(); got != 77 {
		t.Fatalf("surplus = %d, want 77", got)
	}
	liabBefore := Liabilities()
	coinsBefore := coinsOf(testAdmin)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SweepDenom(cross(cur), Denom)

	if got := coinsOf(testAdmin) - coinsBefore; got != 77 {
		t.Fatalf("swept %d, want exactly the 77 surplus", got)
	}
	if Liabilities() != liabBefore {
		t.Fatalf("sweep changed liabilities: %d -> %d", liabBefore, Liabilities())
	}
	if Held() < Liabilities() {
		t.Fatalf("sweep broke solvency: held=%d liabilities=%d", Held(), Liabilities())
	}

	// With no surplus left, sweeping aborts rather than touching reserves.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	uassert.AbortsContains(t, cur, "no surplus to sweep", func() { SweepDenom(cross(cur), Denom) })

	appInvariant(t)
	b.conserved(t, 0)
}

func TestAdminHandoverIsTwoStep(cur realm, t *testing.T) {
	var zero address

	// Only the admin may propose.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	uassert.AbortsContains(t, cur, "admin only", func() { ProposeAdmin(cross(cur), mallory) })

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	ProposeAdmin(cross(cur), funder2)
	if PendingAdmin() != funder2 {
		t.Fatal("proposal not recorded")
	}
	if Admin() != testAdmin {
		t.Fatal("a proposal must not transfer the role on its own")
	}

	// Only the proposed account may accept.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	uassert.AbortsContains(t, cur, "only the proposed admin", func() { AcceptAdmin(cross(cur)) })

	testing.SetRealm(testing.NewUserRealm(funder2))
	testing.SetOriginCaller(funder2)
	AcceptAdmin(cross(cur))
	if Admin() != funder2 || PendingAdmin() != zero {
		t.Fatalf("handover incomplete: admin=%v pending=%v", Admin(), PendingAdmin())
	}

	// Accepting again is refused (the proposal was cleared).
	testing.SetRealm(testing.NewUserRealm(funder2))
	testing.SetOriginCaller(funder2)
	uassert.AbortsContains(t, cur, "only the proposed admin", func() { AcceptAdmin(cross(cur)) })

	// The old admin has lost the role.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	uassert.AbortsContains(t, cur, "admin only", func() { SetFeeBps(cross(cur), 1) })

	// Hand it back so later tests keep their seeded admin.
	testing.SetRealm(testing.NewUserRealm(funder2))
	testing.SetOriginCaller(funder2)
	ProposeAdmin(cross(cur), testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	AcceptAdmin(cross(cur))
	if Admin() != testAdmin {
		t.Fatal("failed to restore the seeded admin")
	}
}

func TestSetFeeBounds(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	uassert.AbortsContains(t, cur, "out of range", func() { SetFeeBps(cross(cur), MaxFeeBps+1) })
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	uassert.AbortsContains(t, cur, "out of range", func() { SetFeeBps(cross(cur), -1) })
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	uassert.AbortsContains(t, cur, "empty fee recipient", func() {
		var zero address
		SetFeeRecipient(cross(cur), zero)
	})
}

// TestStraySendRejected: only Fund accepts value. Every other payable-
// looking entrypoint must refuse an attached envelope rather than absorb
// it into surplus.
func TestStraySendRejected(cur realm, t *testing.T) {
	b := begin()
	id := fundAs(cur, funder1, bene1, 100, "stray", "", "1000:100", true)
	tid := trancheIDsOf(id)[0]

	const guard = "does not accept coins"

	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	testing.SetOriginSend(ugnot(5))
	uassert.AbortsContains(t, cur, guard, func() { Release(cross(cur), tid) }, "Release")

	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	testing.SetOriginSend(ugnot(5))
	uassert.AbortsContains(t, cur, guard, func() { Revoke(cross(cur), tid) }, "Revoke")

	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	testing.SetOriginSend(ugnot(5))
	uassert.AbortsContains(t, cur, guard, func() { RevokeAll(cross(cur), id) }, "RevokeAll")

	testing.SetRealm(testing.NewUserRealm(funder1))
	testing.SetOriginCaller(funder1)
	testing.SetOriginSend(ugnot(5))
	uassert.AbortsContains(t, cur, guard, func() { WithdrawAll(cross(cur)) }, "WithdrawAll")

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(ugnot(5))
	uassert.AbortsContains(t, cur, guard, func() { SetFeeBps(cross(cur), 0) }, "SetFeeBps")

	testing.SetOriginSend(nil)
	appInvariant(t)
	b.conserved(t, 0)
}

func TestUnknownIDsAbort(cur realm, t *testing.T) {
	// The views are non-crossing, and this test file is compiled INTO the
	// realm, so calling one is a same-realm call and its panic is an
	// ordinary panic — not an abort. PanicsContains is the matching
	// assertion; AbortsContains cannot see it and the panic escapes.
	// Off-chain a reader reaches these through vm/qeval, which does cross
	// the boundary and so surfaces the same text as an abort.
	uassert.PanicsContains(t, cur, "unknown schedule id", func() { ScheduleInfo(999999) })
	uassert.PanicsContains(t, cur, "unknown tranche id", func() { TrancheInfo(999999) })
	uassert.PanicsContains(t, cur, "must be positive", func() { TrancheInfo(0) })
	uassert.PanicsContains(t, cur, "must be positive", func() { TrancheInfo(-1) })

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	// Release consumes before it looks anything up, so an unknown id is
	// rejected by duebook and carries duebook's wording, not this realm's
	// "unknown tranche id". That ordering is the replay guard and is not
	// worth reversing for a nicer message: reading the tranches tree first
	// would put a lookup ahead of the consume, which is exactly the shape
	// the consumer contract forbids.
	uassert.AbortsContains(t, cur, "no such open deferral", func() { Release(cross(cur), 999999) })
}

func TestVestedOfTracksTheRevocationBoundary(cur realm, t *testing.T) {
	b := begin()
	id := fundAs(cur, funder1, bene1, 600, "boundary", "", "1:100,2:200,1000:300", false)

	vested, unvested := VestedOf(id)
	if vested != 0 || unvested != 600 {
		t.Fatalf("at funding: vested=%d unvested=%d, want 0/600", vested, unvested)
	}

	testing.SkipHeights(1)
	vested, unvested = VestedOf(id)
	if vested != 100 || unvested != 500 {
		t.Fatalf("after 1 block: vested=%d unvested=%d, want 100/500", vested, unvested)
	}

	testing.SkipHeights(1)
	vested, unvested = VestedOf(id)
	if vested != 300 || unvested != 300 {
		t.Fatalf("after 2 blocks: vested=%d unvested=%d, want 300/300", vested, unvested)
	}

	// Releasing does not change the vested figure: vested means "no longer
	// revocable", whether or not it has been paid out.
	ids := trancheIDsOf(id)
	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginCaller(stranger)
	Release(cross(cur), ids[0])
	vested, unvested = VestedOf(id)
	if vested != 300 || unvested != 300 {
		t.Fatalf("after a release: vested=%d unvested=%d, want 300/300", vested, unvested)
	}

	appInvariant(t)
	b.conserved(t, 0)
}

func TestViewsAndRenderDoNotPanic(cur realm, t *testing.T) {
	// feeBps is a realm global and persists across tests, so a test that
	// asserts a fee-free figure must set the fee it wants rather than
	// inherit whatever the last fee test left — including the case where
	// that test failed before its own reset line ran.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	SetFeeBps(cross(cur), 0)

	b := begin()
	id := fundAs(cur, funder1, bene1, 300, "renderable", "a *memo* with _markdown_", "1:100,900:200", true)

	if out := TranchesOf(id); !strings.Contains(out, StatusPending) {
		t.Fatalf("TranchesOf missing status: %q", out)
	}
	testing.SkipHeights(1)
	if out := ReleasableNow(); out == "" {
		t.Fatal("ReleasableNow empty with a due tranche")
	}
	if fee, credited := FeeOn(1000); fee != 0 || credited != 1000 {
		t.Fatalf("FeeOn at 0 bps = %d/%d", fee, credited)
	}
	if OpenTrancheCount() < 1 {
		t.Fatal("OpenTrancheCount is zero with pending tranches")
	}
	if Height() == 0 {
		t.Fatal("Height() is zero")
	}

	// Assert the STATE-DEPENDENT line, not the heading. "E + U + F + S" is
	// emitted unconditionally as part of the section title, so matching it
	// proves only that Render ran — it would keep passing while the realm
	// rendered "conservation: VIOLATED" underneath.
	if out := Render(""); !strings.Contains(out, "Vesting") ||
		!strings.Contains(out, "conservation: OK") {
		t.Fatalf("overview render wrong: %q", head(out, 400))
	}
	if out := Render(""); !strings.Contains(out, "per funder") {
		t.Fatalf("overview render omits the per-funder cap: %q", head(out, 400))
	}
	if out := Render(itoa(id)); !strings.Contains(out, "Schedule #"+itoa(id)) ||
		!strings.Contains(out, "releasable now") {
		t.Fatalf("detail render wrong: %q", out)
	}
	if out := Render("not-a-number"); !strings.Contains(out, "invalid schedule id") {
		t.Fatalf("bad path render: %q", out)
	}
	if out := Render("999999"); !strings.Contains(out, "unknown schedule id") {
		t.Fatalf("unknown path render: %q", out)
	}

	appInvariant(t)
	b.conserved(t, 0)
}

func head(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
