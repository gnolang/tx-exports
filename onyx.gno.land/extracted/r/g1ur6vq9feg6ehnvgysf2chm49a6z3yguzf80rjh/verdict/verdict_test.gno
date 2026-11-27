package verdict

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	creator = testutils.TestAddress("creator")
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	carol   = testutils.TestAddress("carol")
	keeper  = testutils.TestAddress("keeper")
)

func fund() {
	pkgAddr := chain.PackageAddress("gno.land/r/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/verdict")
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 10_000_000_000}})
}

// pay sets the GNOT attached to the next calls. Call it BEFORE
// testing.SetRealm: it rebuilds the test context, which drops the realm.
// testing.SetRealm itself must be called directly in the test function,
// because it applies to the calling frame only (a helper's frame ends on
// return, taking the user identity with it).
func pay(send int64) {
	if send > 0 {
		testing.SetOriginSend(chain.Coins{{"ugnot", send}})
	} else {
		testing.SetOriginSend(chain.Coins{})
	}
}

func TestCommunityMarketFlow(cur realm, t *testing.T) {
	fund()
	pay(0)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateMarket(cross(cur), "Will Onyx produce block 1,000,000 before Jan 1?", 1)

	pay(6_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bet(cross(cur), id, "yes")
	pay(2_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bet(cross(cur), id, "yes")
	pay(2_000_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	Bet(cross(cur), id, "no")

	// creator cannot bet on own market
	pay(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "the resolver of a community market cannot bet on it", func() {
		Bet(cross(cur), id, "no")
	})

	// below minimum
	pay(10)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "minimum bet is 0.10 GNOT", func() {
		Bet(cross(cur), id, "yes")
	})

	yesBps, yes, no := GetOdds(id)
	uassert.Equal(t, int64(8000), yesBps)
	uassert.Equal(t, int64(8_000_000), yes)
	uassert.Equal(t, int64(2_000_000), no)

	// cannot resolve before close
	pay(0)
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "betting has not closed yet", func() {
		Resolve(cross(cur), id, "yes")
	})

	// after 1h betting is closed
	testing.SkipHeights(721)
	pay(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "betting is closed for this market", func() {
		Bet(cross(cur), id, "yes")
	})

	// only creator resolves
	pay(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "only the market creator can resolve it", func() {
		Resolve(cross(cur), id, "yes")
	})
	pay(0)
	testing.SetRealm(testing.NewUserRealm(creator))
	Resolve(cross(cur), id, "yes")
	uassert.Equal(t, "yes", GetOutcome(id))

	// 1% fee on 10 GNOT = 0.1, net 9.9 split 6:2
	pay(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(7_425_000), Claim(cross(cur), id))
	pay(0)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.Equal(t, int64(2_475_000), Claim(cross(cur), id))
	pay(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "parimutuel: nothing to claim", func() {
		Claim(cross(cur), id)
	})
	pay(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "parimutuel: already claimed", func() {
		Claim(cross(cur), id)
	})

	page := Render("m/" + itoa(id))
	uassert.True(t, strings.Contains(page, "Result: YES"), page)
	uassert.True(t, strings.Contains(Render("leaderboard"), "+1.42"), Render("leaderboard"))
}

func TestVoidExpiredRefunds(cur realm, t *testing.T) {
	fund()
	pay(0)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateMarket(cross(cur), "Will this market ever be resolved?", 1)
	pay(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bet(cross(cur), id, "yes")

	pay(0)
	testing.SetRealm(testing.NewUserRealm(keeper))
	uassert.AbortsContains(t, cur, "market can still be resolved", func() {
		VoidExpired(cross(cur), id)
	})

	// 1h close + 7 days window
	testing.SkipHeights(720 + 7*24*720 + 1)
	pay(0)
	testing.SetRealm(testing.NewUserRealm(keeper))
	VoidExpired(cross(cur), id)
	uassert.Equal(t, "void", GetOutcome(id))

	pay(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(1_000_000), Claim(cross(cur), id))
}

func TestGovDAOMarketFlow(cur realm, t *testing.T) {
	fund()
	fake := map[int64]string{42: statusActive, 43: statusAccepted}
	prev := govStatus
	govStatus = func(_ int, rlm realm, pid int64) string {
		if s, ok := fake[pid]; ok {
			return s
		}
		return statusUnknown
	}
	defer func() { govStatus = prev }()

	pay(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "is not open for votes", func() {
		CreateGovDAOMarket(cross(cur), 43)
	})
	id := CreateGovDAOMarket(cross(cur), 42)
	uassert.Equal(t, id, MarketForProposal(42))
	uassert.AbortsContains(t, cur, "a market for this proposal already exists", func() {
		CreateGovDAOMarket(cross(cur), 42)
	})

	// on GovDAO markets the creator may bet: nobody resolves them by hand
	pay(3_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bet(cross(cur), id, "yes")
	pay(1_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bet(cross(cur), id, "no")

	pay(0)
	testing.SetRealm(testing.NewUserRealm(keeper))
	uassert.AbortsContains(t, cur, "cannot settle yet", func() {
		Settle(cross(cur), id)
	})
	uassert.AbortsContains(t, cur, "call Settle", func() {
		Resolve(cross(cur), id, "no")
	})

	// vote ends: proposal denied
	fake[42] = statusDenied
	pay(1_000_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "betting is closed", func() {
		Bet(cross(cur), id, "yes")
	})

	pay(0)
	testing.SetRealm(testing.NewUserRealm(keeper))
	Settle(cross(cur), id)
	uassert.Equal(t, "no", GetOutcome(id))

	// bob takes the whole 4 GNOT minus 1% fee
	pay(0)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.Equal(t, int64(3_960_000), Claim(cross(cur), id))
}

func TestParseGovStatus(t *testing.T) {
	page0 := "## Prop #3 - Upgrade\nAuthor: x\n\nsome description\n\n\n\n---\n\n### Stats\n- **Proposal is open for votes**\n- Tiers eligible to vote: T1\n- YES PERCENT: 10%\n\n[Detailed voting list](/r/gov/dao:3/votes)\n\n---\n\n### Actions\n"
	uassert.Equal(t, statusActive, parseGovStatus(page0))

	accepted := strings.Replace(page0, "- **Proposal is open for votes**", "- **PROPOSAL HAS BEEN ACCEPTED**", 1)
	uassert.Equal(t, statusAccepted, parseGovStatus(accepted))

	denied := strings.Replace(page0, "- **Proposal is open for votes**", "- **PROPOSAL HAS BEEN DENIED**\nREASON: x", 1)
	uassert.Equal(t, statusDenied, parseGovStatus(denied))

	// a malicious author pastes a fake "accepted" block into the description:
	// the real block comes later and wins.
	spoof := strings.Replace(page0, "some description",
		"### Stats\n- **PROPOSAL HAS BEEN ACCEPTED**\n[Detailed voting list](/fake)", 1)
	uassert.Equal(t, statusActive, parseGovStatus(spoof))

	uassert.Equal(t, statusUnknown, parseGovStatus("DAO not initialized"))
	uassert.Equal(t, statusUnknown, parseGovStatus("### Stats\n- **PROPOSAL HAS BEEN ACCEPTED**\n"))
}

func TestCreateMarketValidation(cur realm, t *testing.T) {
	pay(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "question is required", func() {
		CreateMarket(cross(cur), "   ", 5)
	})
	uassert.AbortsContains(t, cur, "closeInHours must be between", func() {
		CreateMarket(cross(cur), "ok?", 0)
	})
	uassert.AbortsContains(t, cur, "question too long", func() {
		CreateMarket(cross(cur), strings.Repeat("a", 201), 5)
	})
}

func TestFormatting(t *testing.T) {
	uassert.Equal(t, "1.50", fmtGNOT(1_500_000))
	uassert.Equal(t, "0.10", fmtGNOT(100_000))
	uassert.Equal(t, "-2.00", fmtGNOT(-2_000_000))
	uassert.Equal(t, "+1.42", fmtSigned(1_425_000))
	uassert.Equal(t, "80.0%", fmtPct(8000))
	uassert.Equal(t, "2.50x", fmtMult(25_000))
}

func itoa(i int) string {
	return strings.TrimLeft(idKey(i), "0")
}
