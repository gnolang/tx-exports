package bugtavern

import (
	"testing"

	"chain"
	"chain/banker"

	"gno.land/p/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/tavernrules"
	"gno.land/p/nt/avl/v0"
)

const (
	testSponsorAddr = "g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m"
	testArbiterAddr = "g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg"
	testHunterAddr  = "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
	testHunter2Addr = "g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar"
	testPkgPath     = "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
)

const (
	testTitle = "Missing access control on Withdraw"
	testPoc   = "https://example.com/poc"
	testSalt  = "saltsaltsaltsalt"
)

func resetRealmState() {
	bounties = avl.NewTree()
	findings = avl.NewTree()
	ledger = avl.NewTree()
	nextBountyID = 1
	nextFindingID = 1
	nextLedgerID = 1
}

// openTestBounty creates bounty 1 (tiers 5/3/1/0.5 GNOT) as the
// sponsor at height 1000. The caller must have set the realm to the
// sponsor and the origin send to exactly 9500000ugnot first.
func openTestBounty(cur realm) uint64 {
	return CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000,
		address(testArbiterAddr), 24600)
}

// commitTestFinding commits finding 1 for bounty 1 as the hunter at
// the current height and returns its id.
func commitTestFinding(cur realm) uint64 {
	hash := tavernrules.MakeCommitment(1, tavernrules.SevCritical,
		testTitle, testPoc, testSalt)
	return CommitFinding(cross(cur), 1, hash, uint8(tavernrules.SevCritical))
}

// TestGlueHappyPath runs the design §6.4 happy path through the
// crossing glue functions with a funded realm: create → commit →
// reveal → verdict Accept → payout. It asserts state, totals, AND
// real bank balances (the realm is funded with testing.IssueCoins,
// the same mechanism the disperse filetests use — unlike the // SEND:
// envelope, issued coins really move on SendCoins).
func TestGlueHappyPath(cur realm, t *testing.T) {
	resetRealmState()
	sponsor := address(testSponsorAddr)
	arbiter := address(testArbiterAddr)
	hunter := address(testHunterAddr)
	realmAddr := chain.PackageAddress(testPkgPath)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetHeight(1000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 9500000)))
	bountyID := openTestBounty(cur)
	if bountyID != 1 {
		t.Fatalf("CreateBounty id = %d, want 1", bountyID)
	}
	// No coins may ride on the non-payment calls.
	testing.SetOriginSend(chain.NewCoins())
	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	findingID := commitTestFinding(cur)
	if findingID != 1 {
		t.Fatalf("CommitFinding id = %d, want 1", findingID)
	}
	testing.SetHeight(1002)
	RevealFinding(cross(cur), findingID, testTitle, testPoc, testSalt)
	if got := GetFinding(findingID); got.Status() != tavernrules.FindingRevealed {
		t.Fatalf("after reveal status = %s, want Revealed", got.Status())
	}
	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1003)
	Verdict(cross(cur), findingID, uint8(tavernrules.VerdictAccept), uint8(tavernrules.SevCritical), "confirmed, drains vault", 0)
	f := GetFinding(findingID)
	if f.Status() != tavernrules.FindingAccepted {
		t.Fatalf("after verdict status = %s, want Accepted", f.Status())
	}
	if f.PaidAmount() != 5000000 {
		t.Fatalf("PaidAmount = %d, want 5000000", f.PaidAmount())
	}
	tot := GetTotals()
	if tot.PaidOut != 5000000 || tot.Locked != 4500000 {
		t.Fatalf("totals paid/locked = %d/%d, want 5000000/4500000", tot.PaidOut, tot.Locked)
	}
	bank := banker.NewReadonlyBanker()
	if got := bank.GetCoin(hunter, "ugnot"); got != 5000000 {
		t.Fatalf("hunter bank balance = %d, want 5000000", got)
	}
	if got := bank.GetCoin(realmAddr, "ugnot"); got != 4500000 {
		t.Fatalf("realm bank balance = %d, want 4500000", got)
	}
	// MarkFixed discloses the accepted finding.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1004)
	MarkFixed(cross(cur), bountyID)
	if got := GetFinding(findingID); got.Status() != tavernrules.FindingDisclosed {
		t.Fatalf("after MarkFixed status = %s, want Disclosed", got.Status())
	}
}

func TestVerdictSeverityCorrection(cur realm, t *testing.T) {
	// Design §5.3 / README deviation 20 (resolved day 6): the arbiter
	// (and the sponsor as backup) may correct the hunter's claimed
	// severity up or down, and the price follows the FINAL tier.
	resetRealmState()
	sponsor := address(testSponsorAddr)
	arbiter := address(testArbiterAddr)
	hunter := address(testHunterAddr)
	realmAddr := chain.PackageAddress(testPkgPath)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 19000000}})

	// Case 1: claim Critical, arbiter corrects DOWN to High -> paid
	// the High price (3,000,000), not the Critical price (5,000,000).
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 9500000)))
	b1 := openTestBounty(cur)
	testing.SetOriginSend(chain.NewCoins())
	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	f1 := commitTestFinding(cur)
	testing.SetHeight(1002)
	RevealFinding(cross(cur), f1, testTitle, testPoc, testSalt)
	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1003)
	Verdict(cross(cur), f1, uint8(tavernrules.VerdictAccept),
		uint8(tavernrules.SevHigh), "overstated: no fund loss, High at most", 0)
	g1 := GetFinding(f1)
	if g1.SeverityFinal() != tavernrules.SevHigh {
		t.Fatalf("corrected severity = %s, want High", g1.SeverityFinal())
	}
	if g1.PaidAmount() != 3000000 {
		t.Fatalf("corrected-down payout = %d, want 3000000 (High price)", g1.PaidAmount())
	}
	if got := GetBounty(b1).PoolLeft(); got != 6500000 {
		t.Fatalf("bounty 1 pool left = %d, want 6500000", got)
	}

	// Case 2: claim Low, sponsor (arbiter silent) corrects UP to
	// Medium -> paid the Medium price (1,000,000), not Low (500,000).
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1004)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 9500000)))
	b2 := CreateBounty(cross(cur),
		"Second audit", "Audit the vault realm again.",
		5000000, 3000000, 1000000, 500000,
		address(testArbiterAddr), 24600)
	testing.SetOriginSend(chain.NewCoins())
	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1005)
	title2 := "Weak randomness in lottery"
	poc2 := "https://example.com/poc2"
	salt2 := "anothersaltsalts"
	hash2 := tavernrules.MakeCommitment(b2, tavernrules.SevLow, title2, poc2, salt2)
	f2 := CommitFinding(cross(cur), b2, hash2, uint8(tavernrules.SevLow))
	testing.SetHeight(1006)
	RevealFinding(cross(cur), f2, title2, poc2, salt2)
	// Arbiter stays silent past the review deadline (1006+72000).
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(73007)
	SponsorVerdict(cross(cur), f2, uint8(tavernrules.VerdictAccept),
		uint8(tavernrules.SevMedium), "understated: exploitable, Medium", 0)
	g2 := GetFinding(f2)
	if g2.SeverityFinal() != tavernrules.SevMedium {
		t.Fatalf("corrected severity = %s, want Medium", g2.SeverityFinal())
	}
	if g2.PaidAmount() != 1000000 {
		t.Fatalf("corrected-up payout = %d, want 1000000 (Medium price)", g2.PaidAmount())
	}
	tot := GetTotals()
	if tot.PaidOut != 4000000 || tot.Locked != 15000000 {
		t.Fatalf("totals paid/locked = %d/%d, want 4000000/15000000", tot.PaidOut, tot.Locked)
	}
}

func TestGettersAndLedger(cur realm, t *testing.T) {
	// Day-6 getters + ledger, over the §6.4 happy path: create ->
	// commit -> reveal -> verdict Accept (5 GNOT). The ledger must
	// hold exactly [lock 9.5M, payout 5M] newest-first, and every
	// read getter must agree with the stored state.
	resetRealmState()
	sponsor := address(testSponsorAddr)
	arbiter := address(testArbiterAddr)
	hunter := address(testHunterAddr)
	realmAddr := chain.PackageAddress(testPkgPath)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetHeight(1000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 9500000)))
	bountyID := openTestBounty(cur)
	testing.SetOriginSend(chain.NewCoins())
	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	findingID := commitTestFinding(cur)
	testing.SetHeight(1002)
	RevealFinding(cross(cur), findingID, testTitle, testPoc, testSalt)
	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1003)
	Verdict(cross(cur), findingID, uint8(tavernrules.VerdictAccept),
		uint8(tavernrules.SevCritical), "confirmed, drains vault", 0)

	// ListBounties: newest-first, pagination clamps.
	bs := ListBounties(0, 20)
	if len(bs) != 1 || bs[0].ID() != bountyID {
		t.Fatalf("ListBounties = %d bounties, want exactly bounty 1", len(bs))
	}
	if got := ListBounties(1, 20); len(got) != 0 {
		t.Fatalf("ListBounties(offset 1) = %d, want 0", len(got))
	}
	if got := ListBounties(0, 0); len(got) != 1 {
		t.Fatalf("ListBounties(limit 0 defaults to 20) = %d, want 1", len(got))
	}
	// Findings by bounty and by hunter.
	fb := FindingsByBounty(bountyID, 0, 20)
	if len(fb) != 1 || fb[0].ID() != findingID {
		t.Fatalf("FindingsByBounty = %d findings, want exactly finding 1", len(fb))
	}
	if got := FindingsByBounty(999, 0, 20); len(got) != 0 {
		t.Fatalf("FindingsByBounty(unknown) = %d, want 0", len(got))
	}
	fh := FindingsByHunter(hunter, 0, 20)
	if len(fh) != 1 || fh[0].ID() != findingID {
		t.Fatalf("FindingsByHunter = %d findings, want exactly finding 1", len(fh))
	}
	// Hunter stats and leaderboards.
	hs := HunterStats(hunter)
	if hs.Submitted() != 1 || hs.Accepted() != 1 || hs.Earned() != 5000000 {
		t.Fatalf("HunterStats = submitted %d accepted %d earned %d, want 1/1/5000000",
			hs.Submitted(), hs.Accepted(), hs.Earned())
	}
	th := TopHunters(25)
	if len(th) != 1 || th[0].Addr() != hunter || th[0].Earned() != 5000000 {
		t.Fatalf("TopHunters = %d hunters, want exactly the hunter with 5000000 earned", len(th))
	}
	ta := TopArbiters(25)
	if len(ta) != 1 || ta[0].Addr() != arbiter || ta[0].Verdicts() != 1 || ta[0].Accepted() != 1 {
		t.Fatalf("TopArbiters = %d arbiters, want exactly the arbiter with 1 accepted verdict", len(ta))
	}
	// Ledger: lock then payout, newest-first.
	if LedgerCount() != 2 {
		t.Fatalf("LedgerCount = %d, want 2 (lock + payout)", LedgerCount())
	}
	le := GetLedger(0, 20)
	if len(le) != 2 {
		t.Fatalf("GetLedger = %d entries, want 2", len(le))
	}
	if le[0].Kind != "payout" || le[0].Amount != 5000000 || le[0].To != hunter || le[0].FindingID != findingID {
		t.Fatalf("ledger[0] = %v, want payout 5000000 to hunter for finding 1", le[0])
	}
	if le[1].Kind != "lock" || le[1].Amount != 9500000 || le[1].To != sponsor || le[1].BountyID != bountyID {
		t.Fatalf("ledger[1] = %v, want lock 9500000 from sponsor for bounty 1", le[1])
	}
	if got := GetLedger(2, 20); len(got) != 0 {
		t.Fatalf("GetLedger(offset 2) = %d, want 0", len(got))
	}
	// TopUp records a second lock entry.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1004)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 500000)))
	TopUpBounty(cross(cur), bountyID)
	if LedgerCount() != 3 {
		t.Fatalf("LedgerCount after top-up = %d, want 3", LedgerCount())
	}
	if got := GetLedger(0, 1); len(got) != 1 || got[0].Kind != "lock" || got[0].Amount != 500000 {
		t.Fatalf("newest ledger entry after top-up = %v, want lock 500000", got)
	}
}

func TestLedgerRefund(cur realm, t *testing.T) {
	// Cancel records a refund entry; the trail sums to the pool.
	resetRealmState()
	sponsor := address(testSponsorAddr)
	realmAddr := chain.PackageAddress(testPkgPath)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetHeight(1000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 9500000)))
	bountyID := openTestBounty(cur)
	testing.SetOriginSend(chain.NewCoins())
	testing.SetHeight(1001)
	CancelBounty(cross(cur), bountyID)
	le := GetLedger(0, 20)
	if len(le) != 2 || le[0].Kind != "refund" || le[0].Amount != 9500000 || le[0].To != sponsor {
		t.Fatalf("ledger after cancel = %v, want [refund 9500000, lock 9500000]", le)
	}
	if le[1].Kind != "lock" || le[1].Amount != 9500000 {
		t.Fatalf("ledger[1] after cancel = %v, want lock 9500000", le[1])
	}
}

func TestMustGetFindingUnknownPanics(t *testing.T) {
	resetRealmState()
	defer func() {
		if r := recover(); r == nil {
			t.Fatalf("mustGetFinding(999) did not panic")
		}
	}()
	mustGetFinding(999)
}

func TestFindingsOfFiltersByBounty(t *testing.T) {
	resetRealmState()
	sponsor := address(testSponsorAddr)
	hunter := address(testHunterAddr)
	b1 := tavernrules.NewBounty(1, sponsor, address(testArbiterAddr), "T1", "S1",
		5000000, 3000000, 1000000, 500000, 1000, 25600)
	b2 := tavernrules.NewBounty(2, sponsor, address(testArbiterAddr), "T2", "S2",
		5000000, 3000000, 1000000, 500000, 1000, 25600)
	bounties.Set(bountyKey(1), b1)
	bounties.Set(bountyKey(2), b2)
	h1 := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	h2 := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	f1 := tavernrules.NewFinding(1, 1, hunter, tavernrules.SevCritical, h1, 1001, 25601)
	f2 := tavernrules.NewFinding(2, 2, hunter, tavernrules.SevHigh, h2, 1001, 25601)
	findings.Set(findingKey(1), f1)
	findings.Set(findingKey(2), f2)
	if got := findingsOf(1); len(got) != 1 || got[0].ID() != 1 {
		t.Fatalf("findingsOf(1) = %d findings, want exactly finding 1", len(got))
	}
	if got := othersOf(1, 1); len(got) != 0 {
		t.Fatalf("othersOf(1, 1) = %d findings, want 0 (self excluded)", len(got))
	}
	if got := othersOf(2, 99); len(got) != 1 || got[0].ID() != 2 {
		t.Fatalf("othersOf(2, 99) = %d findings, want exactly finding 2", len(got))
	}
}

func TestRequireNoCoinsPassesWhenEmpty(t *testing.T) {
	testing.SetOriginSend(chain.NewCoins())
	requireNoCoins()
}

func contains(s, want string) bool {
	for i := 0; i+len(want) <= len(s); i++ {
		if s[i:i+len(want)] == want {
			return true
		}
	}
	return false
}

func TestExampleCommitment(t *testing.T) {
	// Same known vector as the gate probe and tavernrules tests.
	want := "ceba4aa550e737510103fa7a74d5593628ca6afa4d5af1fe43e26ffe4e896c2c"
	if got := ExampleCommitment(); got != want {
		t.Fatalf("ExampleCommitment = %s, want %s", got, want)
	}
}

func TestRenderShowsBugTavern(t *testing.T) {
	// Fresh state so the totals row reads zero.
	bounties = avl.NewTree()
	findings = avl.NewTree()
	ledger = avl.NewTree()
	rendered := Render("")
	if rendered == "" {
		t.Fatal("Render returned empty string")
	}
	for _, want := range []string{"# BugTavern", "0.4.0-day6", "Open bounties", "No open bounties yet"} {
		if !contains(rendered, want) {
			t.Fatalf("Render() missing %q", want)
		}
	}
	// Render never panics on bad paths, ids or addresses.
	for _, bad := range []string{"nope", "bounty/abc", "bounty/999", "finding/xyz", "finding/999", "hunter/not-an-address", "hunter/", "bounty/", "finding/"} {
		if out := Render(bad); !contains(out, "Not found") {
			t.Fatalf("Render(%q) = %q, want the not-found page", bad, out)
		}
	}
}

func TestPadIDOrdering(t *testing.T) {
	if got := padID(1); got != "00000000000000000001" {
		t.Fatalf("padID(1) = %q, want 20-digit zero-padded", got)
	}
	if len(padID(12345678901234567890)) != 20 {
		t.Fatalf("padID(20-digit) length = %d, want 20", len(padID(12345678901234567890)))
	}
	// Lexicographic order must match numeric order (avl keys sort
	// lexicographically; the duplicate tie-break relies on id order).
	if !(padID(2) < padID(10)) {
		t.Fatalf("padID order broken: %q !< %q", padID(2), padID(10))
	}
	if !(bountyKey(2) < bountyKey(10)) {
		t.Fatalf("bountyKey order broken")
	}
}

func TestGetTotalsSumsPools(t *testing.T) {
	bounties = avl.NewTree()
	findings = avl.NewTree()
	sponsor := address("g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m")
	arbiter := address("g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg")
	b1 := tavernrules.NewBounty(1, sponsor, arbiter, "T1", "S1",
		5000000, 3000000, 1000000, 500000, 1000, 25600)
	b2 := tavernrules.NewBounty(2, sponsor, arbiter, "T2", "S2",
		5000000, 3000000, 1000000, 500000, 1000, 25600)
	bounties.Set(bountyKey(1), b1)
	bounties.Set(bountyKey(2), b2)
	tot := GetTotals()
	if tot.Bounties != 2 {
		t.Fatalf("GetTotals().Bounties = %d, want 2", tot.Bounties)
	}
	if tot.Locked != 19000000 {
		t.Fatalf("GetTotals().Locked = %d, want 19000000", tot.Locked)
	}
	if tot.PaidOut != 0 || tot.Refunded != 0 {
		t.Fatalf("GetTotals() paid/refunded = %d/%d, want 0/0", tot.PaidOut, tot.Refunded)
	}
	// GetBounty returns the stored value copy.
	if got := GetBounty(2); got.PoolTotal() != 9500000 {
		t.Fatalf("GetBounty(2).PoolTotal() = %d, want 9500000", got.PoolTotal())
	}
}

func TestMustGetBountyUnknownPanics(t *testing.T) {
	bounties = avl.NewTree()
	defer func() {
		if r := recover(); r == nil {
			t.Fatalf("mustGetBounty(999) did not panic")
		}
	}()
	mustGetBounty(999)
}

func TestCheckedPoolTotalOverflow(t *testing.T) {
	max := int64(9223372036854775807)
	if _, ok := checkedPoolTotal(max, 1, 0, 0); ok {
		t.Fatalf("checkedPoolTotal(MaxInt64, 1, 0, 0) did not overflow")
	}
	if total, ok := checkedPoolTotal(5000000, 3000000, 1000000, 500000); !ok || total != 9500000 {
		t.Fatalf("checkedPoolTotal(5M, 3M, 1M, 0.5M) = %d, %v, want 9500000, true", total, ok)
	}
}
