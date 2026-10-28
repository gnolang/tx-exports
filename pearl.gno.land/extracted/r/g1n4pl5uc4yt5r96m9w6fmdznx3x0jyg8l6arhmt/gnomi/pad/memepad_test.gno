package pad

import (
	"chain"
	"strings"
	"testing"
)

func TestSetGraduationThreshold(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	if GraduationThresholdLive() != GraduationThreshold {
		t.Fatalf("live=%d want default %d", GraduationThresholdLive(), GraduationThreshold)
	}
	SetGraduationThreshold(cross(cur), 500_000_000) // 500 GNOT
	if GraduationThresholdLive() != 500_000_000 {
		t.Fatalf("after set live=%d", GraduationThresholdLive())
	}
	// Non-protocol panic: cross() panics are not recover()-catchable in this gno;
	// covered by requireProtocol guard + manual review.
}

func TestInitAndCreateBuy(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	if !inited {
		t.Fatal("not inited")
	}

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Test Cat", "TCAT", "https://example.com/tcat")
	if id == "" {
		t.Fatal("empty id")
	}
	if ResolveSymbol("TCAT") != id {
		t.Fatal("symbol map")
	}
	if GetStatus(id) != StatusCurve {
		t.Fatal("status")
	}

	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 100000}})
	tok := Buy(cross(cur), id, 0, 0)
	if tok <= 0 {
		t.Fatalf("tokens=%d", tok)
	}
	if BalanceOf(id, buyer) != tok {
		t.Fatalf("bal=%d want %d", BalanceOf(id, buyer), tok)
	}
	if GetRaised(id) <= 0 {
		t.Fatal("raised")
	}
}

func TestSellCurve(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Dog", "DOG", "")
	testing.SkipHeights(21)

	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 500000}})
	// Test env: ensure realm has ugnot to pay sells (OriginSend may not fund banker balance).
	testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 2000000}})
	tok := Buy(cross(cur), id, 0, 0)
	half := tok / 2
	if half <= 0 {
		t.Fatal("half")
	}
	ug := Sell(cross(cur), id, half, 0)
	if ug <= 0 {
		t.Fatalf("ugnot out=%d", ug)
	}
	if BalanceOf(id, buyer) != tok-half {
		t.Fatal("balance after sell")
	}
}

// TestBuyClampsRaise: a single oversized buy near threshold must not overshoot
// GraduationThreshold; market graduates with raised == threshold.
func TestBuyClampsRaise(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	thresh := int64(100_000_000) // 100 GNOT unit-test threshold
	SetGraduationThreshold(cross(cur), thresh)

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Cap", "CAP", "")
	testing.SkipHeights(21)
	testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 200_000_000}})

	// Approach threshold with mid buys, stop before graduate.
	for i := 0; i < 20; i++ {
		if GetRaised(id) >= thresh-2_000_000 {
			break
		}
		if GetStatus(id) == StatusGraduated {
			t.Fatal("graduated too early")
		}
		testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 5_000_000}}) // 5 GNOT
		Buy(cross(cur), id, 0, 0)
	}
	raisedBefore := GetRaised(id)
	if raisedBefore <= 0 {
		t.Fatal("no raise")
	}
	if raisedBefore >= thresh {
		t.Fatalf("already at threshold raised=%d", raisedBefore)
	}
	need := RemainingRaiseUgnot(id)
	if need <= 0 {
		t.Fatalf("need=%d", need)
	}

	// Oversized buy: far more than remaining raise.
	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 50_000_000}}) // 50 GNOT
	tok := Buy(cross(cur), id, 0, 0)
	if tok <= 0 {
		t.Fatal("no tokens on last fill")
	}
	// Graduate zeros Raised into pool - raised should not overshoot threshold.
	if GetStatus(id) != StatusGraduated {
		t.Fatalf("expected graduated status=%d raised=%d before=%d need=%d",
			GetStatus(id), GetRaised(id), raisedBefore, need)
	}
	pu, _ := GetPool(id)
	// Pool ugnot is the raise at graduate; must equal threshold (raise-capped last fill).
	if pu != thresh {
		t.Fatalf("pool ugnot=%d want threshold=%d (before=%d need=%d) - overshoot or underfill",
			pu, thresh, raisedBefore, need)
	}
	if RemainingRaiseUgnot(id) != 0 {
		t.Fatal("remaining raise should be 0 after graduate")
	}
}

// TestGraduateSoldOutBelowThreshold: when RealSold hits CurveSupply but raised is
// still below GraduationThreshold, Graduate must succeed (escape hatch).
func TestGraduateSoldOutBelowThreshold(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Stuck", "STK", "")
	testing.SkipHeights(21)
	testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 200_000_000}})

	// Simulate the padv10 Sapphire bug: full curve float sold, raise under threshold.
	l := mustLaunch(id)
	under := GraduationThreshold - 12_500_000 // e.g. ~87.5 vs 100
	if under <= 0 {
		under = GraduationThreshold / 2
	}
	l.RealSold = CurveSupply
	l.RaisedUgnot = under
	l.VirtualUgnot = VirtualUgnot0 + under
	l.VirtualToken = VirtualToken0 - CurveSupply
	if l.VirtualToken <= 0 {
		l.VirtualToken = 1
	}

	if readyToGraduate(l) != true {
		t.Fatal("expected readyToGraduate on sold-out with raise")
	}
	Graduate(cross(cur), id)
	if GetStatus(id) != StatusGraduated {
		t.Fatalf("status=%d want graduated", GetStatus(id))
	}
	pu, pt := GetPool(id)
	if pu != under {
		t.Fatalf("pool ugnot=%d want raised=%d", pu, under)
	}
	// LP sized to curve spot; when needed >= remaining, equals all unsold (200M).
	remaining := TotalSupply - CurveSupply
	wantPT := remaining
	// Reconstruct pre-graduate virtuals used in GraduateSoldOut setup.
	vu := VirtualUgnot0 + under
	vt := VirtualToken0 - CurveSupply
	if vt <= 0 {
		vt = 1
	}
	if vu > 0 && vt > 0 {
		needed := under * vt / vu
		if needed > 0 && needed < remaining {
			wantPT = needed
		}
	}
	if pt != wantPT {
		t.Fatalf("pool token=%d want %d (seamless LP)", pt, wantPT)
	}
}

// TestGraduateSeamlessPoolSpot: PoolToken is sized so pool open ≈ curve exit,
// not a dump of every unsold token.
func TestGraduateSeamlessPoolSpot(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	// Keep raise small to avoid int64 overflow in needed = raise*vt/vu.
	thresh := int64(100_000_000)
	SetGraduationThreshold(cross(cur), thresh)

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Seam", "SEAM", "")
	testing.SkipHeights(21)

	l := mustLaunch(id)
	// Mid-curve state: plenty of unsold tokens left, raise at threshold.
	// If we dumped ALL remaining into LP, spot would be far below curve.
	l.RealSold = 100_000_000
	l.RaisedUgnot = thresh
	l.VirtualUgnot = VirtualUgnot0 + thresh
	l.VirtualToken = VirtualToken0 - 100_000_000
	if l.VirtualToken <= 0 {
		t.Fatal("bad virtual token")
	}

	vu, vt := l.VirtualUgnot, l.VirtualToken
	Graduate(cross(cur), id)
	if GetStatus(id) != StatusGraduated {
		t.Fatalf("status=%d want graduated", GetStatus(id))
	}
	pu, pt := GetPool(id)
	if pu != thresh {
		t.Fatalf("pool ugnot=%d", pu)
	}
	remaining := TotalSupply - 100_000_000
	needed := thresh * vt / vu
	if needed <= 0 || needed >= remaining {
		t.Fatalf("test setup: needed=%d remaining=%d (want needed < remaining)", needed, remaining)
	}
	if pt != needed {
		t.Fatalf("pool token=%d want seamless needed=%d (not dump remaining=%d)", pt, needed, remaining)
	}
	if l.LeftoverTokens != remaining-needed {
		t.Fatalf("leftover=%d want %d", l.LeftoverTokens, remaining-needed)
	}
	// Spot match within 1%: poolU/poolT ≈ vu/vt
	spotCurve := vu * 1_000_000 / vt
	spotPool := pu * 1_000_000 / pt
	drift := spotCurve - spotPool
	if drift < 0 {
		drift = -drift
	}
	if spotCurve > 0 && drift*100/spotCurve > 1 {
		t.Fatalf("spot drift curve=%d pool=%d (>1%%)", spotCurve, spotPool)
	}
}

// TestBuySoldOutRefundsAndGraduates: Buy after sold-out refunds full send and graduates.
func TestBuySoldOutRefundsAndGraduates(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Sold", "SLD", "")
	testing.SkipHeights(21)
	testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 200_000_000}})

	l := mustLaunch(id)
	under := GraduationThreshold - 12_500_000
	if under <= 0 {
		under = GraduationThreshold / 2
	}
	l.RealSold = CurveSupply
	l.RaisedUgnot = under
	l.VirtualUgnot = VirtualUgnot0 + under
	l.VirtualToken = VirtualToken0 - CurveSupply
	if l.VirtualToken <= 0 {
		l.VirtualToken = 1
	}

	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 15_000_000}}) // 15 GNOT
	tok := Buy(cross(cur), id, 0, 0)
	if tok != 0 {
		t.Fatalf("expected 0 tokens on sold-out buy, got %d", tok)
	}
	if GetStatus(id) != StatusGraduated {
		t.Fatalf("status=%d want graduated after sold-out Buy", GetStatus(id))
	}
	if BalanceOf(id, buyer) != 0 {
		t.Fatal("buyer should not receive tokens on sold-out refund path")
	}
}

// TestRetryListGnoswap: after internal-CPMM graduate, forced list succeeds and
// disables further pad-side listing double-call.
func TestRetryListGnoswap(cur realm, t *testing.T) {
	resetForTest()
	testForceGnoswapList = false
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	SetGraduationThreshold(cross(cur), 100_000_000) // 100 GNOT for fast graduate
	SetListVenue(cross(cur), VenueGnoswap, "Gnoswap", true, "GNS")

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := CreateWithVenue(cross(cur), "ListMe", "LST", "", VenueGnoswap)
	graduateHelper(cur, t, id)
	if GnoswapListedOf(id) {
		t.Fatal("stub should not auto-list")
	}

	// Retry without force still fails (stub).
	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	if RetryListGnoswap(cross(cur), id) {
		t.Fatal("expected retry fail without force flag")
	}
	if GnoswapListedOf(id) {
		t.Fatal("should still be unlisted")
	}

	// Force success path (simulates funded inventory + CreatePool).
	testForceGnoswapList = true
	defer func() { testForceGnoswapList = false }()
	if !RetryListGnoswap(cross(cur), id) {
		t.Fatal("expected retry list success")
	}
	if !GnoswapListedOf(id) {
		t.Fatal("expected GnoswapListed")
	}
	if GnoswapPoolPathOf(id) == "" {
		t.Fatal("empty pool path")
	}
	if ListVenueOf(id) != VenueGnoswap {
		t.Fatalf("ListVenue=%q want gnoswap", ListVenueOf(id))
	}
}

// TestRetryListUnknownVenue: soft-fail with note, no panic / no list.
func TestRetryListUnknownVenue(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	SetGraduationThreshold(cross(cur), 100_000_000)

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "NoVen", "NVN", "")
	graduateHelper(cur, t, id)
	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	if RetryList(cross(cur), id, "uniswap") {
		t.Fatal("unknown venue must not list")
	}
	if GnoswapListedOf(id) || ListedOf(id) {
		t.Fatal("must stay unlisted")
	}
	note := GnoswapNoteOf(id)
	if note == "" {
		t.Fatal("expected skip note")
	}
	venues := ListVenues()
	if !strings.Contains(venues, "gnoswap|") || !strings.Contains(venues, "zdex|") {
		t.Fatalf("ListVenues missing gnoswap/zdex: %s", venues)
	}
}

// graduateHelper: protocol must already have lowered graduation; buys until graduated.
func graduateHelper(cur realm, t *testing.T, id string) {
	t.Helper()
	testing.SkipHeights(21)
	testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 200_000_000}})
	for i := 0; i < 20; i++ {
		if GetStatus(id) == StatusGraduated {
			return
		}
		testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10_000_000}})
		Buy(cross(cur), id, 0, 0)
	}
	if GetStatus(id) != StatusGraduated {
		t.Fatalf("status=%d raised=%d", GetStatus(id), GetRaised(id))
	}
}

// TestCreateFeeByVenue: zdex Create skips GNS escrow; gnoswap locks ListFeeRequired.
func TestCreateFeeByVenue(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	SetListVenue(cross(cur), VenueGnoswap, "Gnoswap", true, "GNS")

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	z := CreateWithVenue(cross(cur), "Zed", "ZED", "", VenueZdex)
	if PreferredVenueOf(z) != VenueZdex {
		t.Fatalf("pref=%q", PreferredVenueOf(z))
	}
	if mustLaunch(z).ListFeeGns != 0 {
		t.Fatalf("zdex fee=%d want 0", mustLaunch(z).ListFeeGns)
	}
	if ListFeeRequiredFor(VenueZdex) != 0 {
		t.Fatal("ListFeeRequiredFor(zdex) want 0")
	}

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	g := CreateWithVenue(cross(cur), "Ged", "GED", "", VenueGnoswap)
	if PreferredVenueOf(g) != VenueGnoswap {
		t.Fatalf("pref=%q", PreferredVenueOf(g))
	}
	want := requiredListFeeGns()
	if mustLaunch(g).ListFeeGns != want {
		t.Fatalf("gnoswap fee=%d want %d", mustLaunch(g).ListFeeGns, want)
	}
	if DefaultListVenue() != VenueZdex {
		t.Fatalf("default=%q want zdex", DefaultListVenue())
	}
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	d := Create(cross(cur), "Def", "DEF", "")
	if PreferredVenueOf(d) != VenueZdex || mustLaunch(d).ListFeeGns != 0 {
		t.Fatal("Create default should be zdex / fee 0")
	}
}

// TestSetPreferredVenueFeeSync: switching venues adjusts GNS escrow.
func TestSetPreferredVenueFeeSync(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	SetListVenue(cross(cur), VenueGnoswap, "Gnoswap", true, "GNS")

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := CreateWithVenue(cross(cur), "Sync", "SYN", "", VenueZdex)
	if mustLaunch(id).ListFeeGns != 0 {
		t.Fatal("start zdex fee 0")
	}
	SetPreferredVenue(cross(cur), id, VenueGnoswap)
	if PreferredVenueOf(id) != VenueGnoswap {
		t.Fatal("pref gnoswap")
	}
	if mustLaunch(id).ListFeeGns != requiredListFeeGns() {
		t.Fatalf("after switch fee=%d", mustLaunch(id).ListFeeGns)
	}
	SetPreferredVenue(cross(cur), id, VenueZdex)
	if mustLaunch(id).ListFeeGns != 0 {
		t.Fatalf("back to zdex fee=%d", mustLaunch(id).ListFeeGns)
	}
}

// TestReleaseListSeedAndConfirmZdex: happy path (panic abuse covered in filetests later).
func TestReleaseListSeedAndConfirmZdex(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	SetGraduationThreshold(cross(cur), 100_000_000)

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := CreateWithVenue(cross(cur), "Zlist", "ZLS", "", VenueZdex)
	graduateHelper(cur, t, id)

	poolU, poolT := GetPool(id)
	if poolU <= 0 || poolT <= 0 {
		t.Fatal("empty pool after graduate")
	}

	ReleaseListSeed(cross(cur), id)
	if !ListSeedReleasedOf(id) {
		t.Fatal("expected ListSeedReleased")
	}
	if BalanceOf(id, creator) < poolT {
		t.Fatalf("creator bal=%d want >= %d", BalanceOf(id, creator), poolT)
	}
	u2, t2 := GetPool(id)
	if u2 != poolU || t2 != poolT {
		t.Fatalf("pool record cleared: %d/%d", u2, t2)
	}

	ConfirmZdexList(cross(cur), id, "ugnot|ZLS")
	if !ListedOf(id) || ListVenueOf(id) != VenueZdex {
		t.Fatal("expected zdex listed")
	}
	if GnoswapPoolPathOf(id) != "ugnot|ZLS" {
		t.Fatalf("poolPath=%q", GnoswapPoolPathOf(id))
	}
	if !GnoswapListedOf(id) {
		t.Fatal("compat GnoswapListed flag")
	}
}

// TestRetryListZdexStubSoftFail: VenueZdex adapter soft-fails without force.
func TestRetryListZdexStubSoftFail(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	SetGraduationThreshold(cross(cur), 100_000_000)

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := CreateWithVenue(cross(cur), "StubZ", "STZ", "", VenueZdex)
	graduateHelper(cur, t, id)

	if RetryList(cross(cur), id, VenueZdex) {
		t.Fatal("stub must soft-fail")
	}
	if ListedOf(id) {
		t.Fatal("must stay unlisted")
	}
	if !strings.Contains(GnoswapNoteOf(id), "ReleaseListSeed") {
		t.Fatalf("note=%q", GnoswapNoteOf(id))
	}
}

func TestGraduateAndSwap(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	SetGraduationThreshold(cross(cur), 100_000_000)

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Moon", "MOON", "")

	// Past anti-snipe window
	testing.SkipHeights(21)

	// Fund realm for pool swap-outs later.
	testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 200_000_000}})
	// Mid-size buys to reach 100 GNOT test graduation threshold.
	for i := 0; i < 20; i++ {
		if GetStatus(id) == StatusGraduated {
			break
		}
		testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10_000_000}}) // 10 GNOT each
		Buy(cross(cur), id, 0, 0)
	}
	if GetStatus(id) != StatusGraduated {
		t.Fatalf("status=%d raised=%d", GetStatus(id), GetRaised(id))
	}
	pu, pt := GetPool(id)
	// LP tokens = TotalSupply - RealSold (all unsold, not only PoolSeed).
	if pu <= 0 || pt <= 0 {
		t.Fatalf("pool u=%d t=%d", pu, pt)
	}
	if pt > TotalSupply {
		t.Fatalf("pool tokens %d > total supply", pt)
	}

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	t2 := SwapBuy(cross(cur), id, 0, 0)
	if t2 <= 0 {
		t.Fatal("swap buy")
	}

	sellAmt := t2 / 2
	if sellAmt <= 0 {
		sellAmt = 1
	}
	u2 := SwapSell(cross(cur), id, sellAmt, 0)
	if u2 <= 0 {
		t.Fatalf("swap sell %d", u2)
	}
}

func TestClaimCreator(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))

	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Fee", "FEE", "")
	testing.SkipHeights(21)

	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 2000000}})
	Buy(cross(cur), id, 0, 0)

	if GetCreatorFees(id) <= 0 {
		t.Fatal("expected creator fees")
	}
	testing.SetRealm(testing.NewUserRealm(creator))
	got := ClaimCreatorFees(cross(cur), id)
	if got <= 0 {
		t.Fatal("claim")
	}
	if GetCreatorFees(id) != 0 {
		t.Fatal("fees not cleared")
	}
}

func TestRender(t *testing.T) {
	resetForTest()
	s := Render("")
	if s == "" {
		t.Fatal("empty render")
	}
	s2 := Render("help")
	if s2 == "" {
		t.Fatal("help")
	}
}

func TestListAndInfo(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "UI Coin", "UIC", "uri")
	ids := ListIDs()
	if ids != id {
		t.Fatalf("ListIDs=%q want %q", ids, id)
	}
	info := LaunchInfo(id)
	if info == "" || len(info) < 10 {
		t.Fatal("LaunchInfo empty")
	}
	p := ParamsInfo()
	if p == "" {
		t.Fatal("ParamsInfo")
	}
}

func TestTradeHistoryChart(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Chart", "CHT", "")
	if TradeCount(id) < 1 {
		t.Fatal("open mark missing")
	}
	testing.SkipHeights(21)
	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 300000}})
	Buy(cross(cur), id, 0, 0)
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 400000}})
	Buy(cross(cur), id, 0, 0)
	if TradeCount(id) < 3 {
		t.Fatalf("trade count=%d want >=3", TradeCount(id))
	}
	hist := TradeHistory(id)
	if hist == "" {
		t.Fatal("empty history")
	}
}

func TestSlippageMinOutOk(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	creator := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: CreateBondUgnot}})
	id := Create(cross(cur), "Slip", "SLP", "")
	testing.SkipHeights(21)

	buyer := address("g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq")
	testing.SetRealm(testing.NewUserRealm(buyer))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 100000}})
	// minTokensOut=1 should pass for a normal small buy
	tok := Buy(cross(cur), id, 0, 1)
	if tok < 1 {
		t.Fatalf("tokens=%d", tok)
	}
}

func TestTransferProtocol(cur realm, t *testing.T) {
	resetForTest()
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	Init(cross(cur))
	if ProtocolAddress() != admin.String() {
		t.Fatal("protocol addr")
	}
	newP := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	TransferProtocol(cross(cur), newP)
	if ProtocolAddress() != newP.String() {
		t.Fatal("not rotated")
	}
}
