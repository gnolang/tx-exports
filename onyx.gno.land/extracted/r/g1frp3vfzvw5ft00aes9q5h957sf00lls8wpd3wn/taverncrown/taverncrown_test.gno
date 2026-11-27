package taverncrown

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
)

const testPkgPath = "gno.land/r/g1frp3vfzvw5ft00aes9q5h957sf00lls8wpd3wn/taverncrown"

var (
	alice = chain.PackageAddress("gno.land/r/test/alice")
	bob   = chain.PackageAddress("gno.land/r/test/bob")
	carol = chain.PackageAddress("gno.land/r/test/carol")
)

func resetState() {
	holder = ""
	pot = 0
	price = basePrice
	deadline = 0
	round = 1
	seizures = 0
	winners = nil
	testing.SetHeight(1000)
	// Fund the realm so refunds/payouts have balance in the harness
	// (SetOriginSend only sets the envelope metadata in tests).
	testing.IssueCoins(chain.PackageAddress(testPkgPath), chain.Coins{{"ugnot", 1_000_000_000}})
}

func seizeAs(cur realm, who address, amount int64) {
	testing.SetRealm(testing.NewUserRealm(who))
	testing.SetOriginSend(chain.Coins{{"ugnot", amount}})
	SeizeCrown(cross(cur))
}

func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, denom)
}

func mustEqual(t *testing.T, want, got any, what string) {
	t.Helper()
	if want != got {
		t.Fatalf("%s: want %v, got %v", what, want, got)
	}
}

func mustTrue(t *testing.T, cond bool, what string) {
	t.Helper()
	if !cond {
		t.Fatalf("expected true: %s", what)
	}
}

func mustAbort(t *testing.T, wantMsg string, f func()) {
	t.Helper()
	r := revive(f)
	if r == nil {
		t.Fatalf("expected abort %q, but call succeeded", wantMsg)
	}
	if s, ok := r.(string); !ok || s != wantMsg {
		t.Fatalf("expected abort %q, got %v", wantMsg, r)
	}
}

func TestSeizeCrown_Basic(cur realm, t *testing.T) {
	resetState()

	seizeAs(cur, alice, basePrice)

	mustEqual(t, alice, holder, "holder")
	mustEqual(t, basePrice, pot, "pot")
	mustEqual(t, basePrice*priceNum/priceDen, price, "next price")
	mustEqual(t, int64(1000)+roundBlocks, deadline, "deadline")
	mustEqual(t, 1, seizures, "seizures")
	mustEqual(t, 1, round, "round")
}

func TestSeizeCrown_UnderpayReverts(cur realm, t *testing.T) {
	resetState()

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", basePrice - 1}})
	mustAbort(t, "payment below current crown price", func() {
		SeizeCrown(cross(cur))
	})
	mustEqual(t, address(""), holder, "holder unchanged")
	mustEqual(t, int64(0), pot, "pot unchanged")
}

func TestSeizeCrown_ExcessRefunded(cur realm, t *testing.T) {
	resetState()
	excess := int64(500_000)

	seizeAs(cur, alice, basePrice+excess)

	mustEqual(t, basePrice, pot, "only the price enters the pot")
	mustEqual(t, excess, balanceOf(alice), "excess refunded to sender")
}

func TestSeizeCrown_PriceCurveAndTakeover(cur realm, t *testing.T) {
	resetState()

	seizeAs(cur, alice, basePrice)
	p2 := price
	seizeAs(cur, bob, p2)

	mustEqual(t, bob, holder, "holder")
	mustEqual(t, basePrice+p2, pot, "pot")
	mustEqual(t, p2*priceNum/priceDen, price, "next price")
	mustEqual(t, 2, seizures, "seizures")
	mustEqual(t, int64(1000)+roundBlocks, deadline, "deadline resets on seizure")
}

func TestClaimPot_BeforeDeadlineReverts(cur realm, t *testing.T) {
	resetState()
	seizeAs(cur, alice, basePrice)

	testing.SetRealm(testing.NewUserRealm(alice))
	mustAbort(t, "round not finished yet", func() {
		ClaimPot(cross(cur))
	})
	mustEqual(t, alice, holder, "holder unchanged")
}

func TestClaimPot_NoRoundReverts(cur realm, t *testing.T) {
	resetState()

	testing.SetRealm(testing.NewUserRealm(alice))
	mustAbort(t, "no active round", func() {
		ClaimPot(cross(cur))
	})
}

func TestClaimPot_PaysHolderAndResets(cur realm, t *testing.T) {
	resetState()

	seizeAs(cur, alice, basePrice)
	p2 := price
	seizeAs(cur, bob, p2)
	totalPot := pot

	// Advance past the deadline; a third party triggers the payout.
	testing.SkipHeights(roundBlocks)
	testing.SetRealm(testing.NewUserRealm(carol))
	ClaimPot(cross(cur))

	mustEqual(t, totalPot, balanceOf(bob), "pot goes to the holder, not the caller")
	mustEqual(t, int64(0), balanceOf(carol), "caller gets nothing")
	mustEqual(t, address(""), holder, "holder reset")
	mustEqual(t, int64(0), pot, "pot reset")
	mustEqual(t, basePrice, price, "price reset")
	mustEqual(t, 0, seizures, "seizures reset")
	mustEqual(t, 2, round, "round increments")
	mustEqual(t, 1, len(winners), "one winner recorded")
	mustEqual(t, bob, winners[0].addr, "winner addr")
	mustEqual(t, totalPot, winners[0].amount, "winner amount")
	mustEqual(t, 1, winners[0].round, "winner round")

	// Double claim reverts: the round is gone.
	mustAbort(t, "no active round", func() {
		ClaimPot(cross(cur))
	})
}

func TestSeizeCrown_AfterExpirySettlesFirst(cur realm, t *testing.T) {
	resetState()

	seizeAs(cur, alice, basePrice)
	testing.SkipHeights(roundBlocks + 5)

	// Bob seizes after expiry: Alice must be paid the old pot first,
	// and Bob's seizure opens round 2 at the base price.
	seizeAs(cur, bob, basePrice)

	mustEqual(t, basePrice, balanceOf(alice), "expired round pays its holder")
	mustEqual(t, bob, holder, "new holder")
	mustEqual(t, basePrice, pot, "new round pot holds only the new payment")
	mustEqual(t, 2, round, "round 2")
	mustEqual(t, 1, len(winners), "one winner recorded")
	mustEqual(t, alice, winners[0].addr, "winner is alice")
}

func TestSeizeCrown_SameHolderExtends(cur realm, t *testing.T) {
	resetState()

	seizeAs(cur, alice, basePrice)
	testing.SkipHeights(100)
	seizeAs(cur, alice, price)

	mustEqual(t, alice, holder, "holder")
	mustEqual(t, 2, seizures, "seizures")
	mustEqual(t, int64(1000)+100+roundBlocks, deadline, "timer resets from latest seizure")
}

func TestRender(cur realm, t *testing.T) {
	resetState()

	home := Render("")
	mustTrue(t, strings.Contains(home, "No reigning monarch"), "empty home page")

	seizeAs(cur, alice, basePrice)
	home = Render("")
	mustTrue(t, strings.Contains(home, string(alice)), "home shows holder")
	mustTrue(t, strings.Contains(home, "Pot:** 1 GNOT"), "home shows pot")

	mustTrue(t, strings.Contains(Render("rules"), "Price curve"), "rules page")
	mustTrue(t, strings.Contains(Render("winners"), "No champions yet"), "empty winners page")

	// Unknown paths never echo user input.
	out := Render("<script>alert(1)</script>")
	mustTrue(t, !strings.Contains(out, "<script>"), "path not echoed")

	// After a settled round, the hall of fame lists the winner.
	testing.SkipHeights(roundBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	ClaimPot(cross(cur))
	w := Render("winners")
	mustTrue(t, strings.Contains(w, string(alice)), "winners lists alice")
	mustTrue(t, strings.Contains(w, "| 1 |"), "winners lists round 1")
}

func TestFormatGNOT(t *testing.T) {
	mustEqual(t, "0", formatGNOT(0), "zero")
	mustEqual(t, "1", formatGNOT(1_000_000), "one")
	mustEqual(t, "1.1", formatGNOT(1_100_000), "one point one")
	mustEqual(t, "0.000001", formatGNOT(1), "one ugnot")
	mustEqual(t, "2.5", formatGNOT(2_500_000), "two point five")
	mustEqual(t, "10.05", formatGNOT(10_050_000), "ten point zero five")
}
