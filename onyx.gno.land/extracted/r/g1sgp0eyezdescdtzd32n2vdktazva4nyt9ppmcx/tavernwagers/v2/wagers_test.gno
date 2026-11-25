package tavernwagers

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	pkgAddr = chain.PackageAddress("gno.land/r/g1sgp0eyezdescdtzd32n2vdktazva4nyt9ppmcx/tavernwagers/v2")
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	judge1  = testutils.TestAddress("judge1")
	judge2  = testutils.TestAddress("judge2")
	judge3  = testutils.TestAddress("judge3")
	outside = testutils.TestAddress("outside")
)

const (
	stake int64 = 1_000_000
	bond  int64 = 100_000
)

func balance(who address) int64 {
	return banker.NewReadonlyBanker().GetCoins(who).AmountOf("ugnot")
}

// setupBody is pasted into each test (cross() calls must happen in the test's
// own frame for testing.SetRealm to take effect).
func TestAgreedResult(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Friday chess club", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	AddMember(cross(cur), tid, judge1, "Judge One")
	AddMember(cross(cur), tid, judge2, "Judge Two")
	AddMember(cross(cur), tid, judge3, "Judge Three")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	bid := CreateBet(cross(cur), tid, "Alice beats Bob, 10 min blitz", "bob", stake)
	uassert.Equal(t, "open", GetBetStatus(bid))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	AcceptBet(cross(cur), bid)
	uassert.Equal(t, "live", GetBetStatus(bid))
	a0, b0 := balance(alice), balance(bob)

	testing.SetRealm(testing.NewUserRealm(alice))

	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "a")
	uassert.Equal(t, "live", GetBetStatus(bid)) // waiting for bob

	testing.SetRealm(testing.NewUserRealm(bob))

	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "A") // case-insensitive
	uassert.Equal(t, "settled", GetBetStatus(bid))
	uassert.Equal(t, "a", GetBetResult(bid))

	// Alice: whole pot + her bond. Bob: his bond back. No fee when players agree.
	uassert.Equal(t, a0+2*stake+bond, balance(alice))
	uassert.Equal(t, b0+bond, balance(bob))

	uassert.Equal(t, stake, GetNet(tid, alice))
	uassert.Equal(t, -stake, GetNet(tid, bob))
}

func TestDisputeLiarLosesBond(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Friday chess club", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	AddMember(cross(cur), tid, judge1, "Judge One")
	AddMember(cross(cur), tid, judge2, "Judge Two")
	AddMember(cross(cur), tid, judge3, "Judge Three")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	bid := CreateBet(cross(cur), tid, "Alice beats Bob, 10 min blitz", "bob", stake)
	uassert.Equal(t, "open", GetBetStatus(bid))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	AcceptBet(cross(cur), bid)
	uassert.Equal(t, "live", GetBetStatus(bid))
	a0, b0 := balance(alice), balance(bob)
	j10, j20, j30 := balance(judge1), balance(judge2), balance(judge3)

	testing.SetRealm(testing.NewUserRealm(alice))

	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "a")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "b") // bob lies
	uassert.Equal(t, "disputed", GetBetStatus(bid))

	// Players can't vote on their own bet, outsiders can't either.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "you are not a judge on this bet", func() { Vote(cross(cur), bid, "b") })
	testing.SetRealm(testing.NewUserRealm(outside))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "you are not a judge on this bet", func() { Vote(cross(cur), bid, "b") })

	testing.SetRealm(testing.NewUserRealm(judge1))

	testing.SetOriginSend(nil)
	Vote(cross(cur), bid, "a")
	uassert.AbortsWithMessage(t, cur, "you already voted", func() { Vote(cross(cur), bid, "a") })
	uassert.Equal(t, "disputed", GetBetStatus(bid)) // 1 of 3 is not a majority

	testing.SetRealm(testing.NewUserRealm(judge2))

	testing.SetOriginSend(nil)
	Vote(cross(cur), bid, "a") // 2 of 3: majority, settles now
	uassert.Equal(t, "settled", GetBetStatus(bid))

	// pot 2,000,000; fee 1% = 20,000; bob's bond 100,000 forfeited:
	// 50,000 to alice, 50,000 to judges. Judges split 70,000.
	uassert.Equal(t, a0+2*stake-20_000+bond+50_000, balance(alice))
	uassert.Equal(t, b0, balance(bob))
	uassert.Equal(t, j10+35_000, balance(judge1))
	uassert.Equal(t, j20+35_000, balance(judge2))
	uassert.Equal(t, j30, balance(judge3)) // didn't vote, gets nothing

	// Every coin that went in came back out.
	got := (balance(alice) - a0) + (balance(bob) - b0) + (balance(judge1) - j10) + (balance(judge2) - j20)
	uassert.Equal(t, 2*(stake+bond), got)

	r := Render("table/" + itoa(tid))
	uassert.True(t, strings.Contains(r, "🚩 1"), "leaderboard should flag bob")
	bp := Render("bet/" + itoa(bid))
	uassert.True(t, strings.Contains(bp, "liar's bond"), "bet page should show payouts")
	uassert.True(t, strings.Contains(bp, "Run it back"), "settled bet offers a rematch")
	uassert.True(t, strings.Contains(bp, "Head to head"), "settled bet shows head to head")
}

func TestDisputeDraw(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Friday chess club", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	AddMember(cross(cur), tid, judge1, "Judge One")
	AddMember(cross(cur), tid, judge2, "Judge Two")
	AddMember(cross(cur), tid, judge3, "Judge Three")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	bid := CreateBet(cross(cur), tid, "Alice beats Bob, 10 min blitz", "bob", stake)
	uassert.Equal(t, "open", GetBetStatus(bid))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	AcceptBet(cross(cur), bid)
	uassert.Equal(t, "live", GetBetStatus(bid))
	_ = tid
	a0, b0 := balance(alice), balance(bob)

	testing.SetRealm(testing.NewUserRealm(alice))

	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "a")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "b")

	testing.SetRealm(testing.NewUserRealm(judge1))

	testing.SetOriginSend(nil)
	Vote(cross(cur), bid, "draw")
	testing.SetRealm(testing.NewUserRealm(judge2))
	testing.SetOriginSend(nil)
	Vote(cross(cur), bid, "draw")

	// Both lied (neither said draw): both lose their bonds to the judges.
	uassert.Equal(t, a0+stake-10_000, balance(alice))
	uassert.Equal(t, b0+stake-10_000, balance(bob))
}

func TestExpiredDisputeRefunds(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Friday chess club", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	AddMember(cross(cur), tid, judge1, "Judge One")
	AddMember(cross(cur), tid, judge2, "Judge Two")
	AddMember(cross(cur), tid, judge3, "Judge Three")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	bid := CreateBet(cross(cur), tid, "Alice beats Bob, 10 min blitz", "bob", stake)
	uassert.Equal(t, "open", GetBetStatus(bid))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	AcceptBet(cross(cur), bid)
	uassert.Equal(t, "live", GetBetStatus(bid))
	_ = tid
	a0, b0 := balance(alice), balance(bob)

	testing.SetRealm(testing.NewUserRealm(alice))

	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "a")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "b")
	testing.SetRealm(testing.NewUserRealm(judge1))
	testing.SetOriginSend(nil)
	Vote(cross(cur), bid, "a")
	testing.SetRealm(testing.NewUserRealm(judge2))
	testing.SetOriginSend(nil)
	Vote(cross(cur), bid, "b")

	testing.SetRealm(testing.NewUserRealm(outside))

	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "voting is still open", func() { ExpireDispute(cross(cur), bid) })

	testing.SkipHeights(50_000) // well past the 48h vote window
	testing.SetRealm(testing.NewUserRealm(outside))
	testing.SetOriginSend(nil)
	ExpireDispute(cross(cur), bid)
	uassert.Equal(t, "refunded", GetBetStatus(bid))
	uassert.Equal(t, a0+stake+bond, balance(alice))
	uassert.Equal(t, b0+stake+bond, balance(bob))
}

func TestEscalateNoShow(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Friday chess club", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	AddMember(cross(cur), tid, judge1, "Judge One")
	AddMember(cross(cur), tid, judge2, "Judge Two")
	AddMember(cross(cur), tid, judge3, "Judge Three")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	bid := CreateBet(cross(cur), tid, "Alice beats Bob, 10 min blitz", "bob", stake)
	uassert.Equal(t, "open", GetBetStatus(bid))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	AcceptBet(cross(cur), bid)
	uassert.Equal(t, "live", GetBetStatus(bid))
	_ = tid

	testing.SetRealm(testing.NewUserRealm(alice))

	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "a")
	uassert.AbortsWithMessage(t, cur, "the other player still has time to report", func() { Escalate(cross(cur), bid) })

	testing.SkipHeights(20_000) // past the 24h report window
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Escalate(cross(cur), bid)
	uassert.Equal(t, "disputed", GetBetStatus(bid))
}

func TestCancelAndValidation(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Validation table", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")

	testing.SetRealm(testing.NewUserRealm(bob))

	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the table owner can add members", func() { AddMember(cross(cur), tid, judge1, "Judge One") })

	// Wrong amount sent.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake}})
	uassert.AbortsWithMessage(t, cur, "send exactly 1100000ugnot (stake + 10% bond)", func() {
		CreateBet(cross(cur), tid, "bad send", "Bob", stake)
	})

	// Opponent not at the table.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	uassert.AbortsWithMessage(t, cur, "opponent is not a member of this table", func() {
		CreateBet(cross(cur), tid, "who?", outside.String(), stake)
	})

	testing.SetRealm(testing.NewUserRealm(alice))

	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	bid := CreateBet(cross(cur), tid, "cancel me", bob.String(), stake)

	testing.SetRealm(testing.NewUserRealm(bob))

	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the player who created the bet can cancel it", func() { CancelBet(cross(cur), bid) })

	a0 := balance(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelBet(cross(cur), bid)
	uassert.Equal(t, "cancelled", GetBetStatus(bid))
	uassert.Equal(t, a0+stake+bond, balance(alice))
}

func TestNoJudgesRefunds(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Just us two", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	bid := CreateBet(cross(cur), tid, "no judges", "Bob", stake)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake+bond}})
	AcceptBet(cross(cur), bid)

	a0, b0 := balance(alice), balance(bob)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "a")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Report(cross(cur), bid, "b")
	uassert.Equal(t, "refunded", GetBetStatus(bid))
	uassert.Equal(t, a0+stake+bond, balance(alice))
	uassert.Equal(t, b0+stake+bond, balance(bob))
}

func TestNicknames(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Nick table", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	uassert.AbortsWithMessage(t, cur, "nickname already taken at this table", func() { AddMember(cross(cur), tid, judge1, "bob") })
	uassert.AbortsWithMessage(t, cur, "nickname can only use letters, numbers, spaces, - _ .", func() { AddMember(cross(cur), tid, judge1, "<b>hi</b>") })

	testing.SetRealm(testing.NewUserRealm(bob))
	SetNickname(cross(cur), tid, "Bobby")
	testing.SetRealm(testing.NewUserRealm(outside))
	uassert.AbortsWithMessage(t, cur, "you are not a member of this table", func() { SetNickname(cross(cur), tid, "Hacker") })

	r := Render("table/" + itoa(tid))
	uassert.True(t, strings.Contains(r, "**Bobby**"), "new nickname shown")
	uassert.True(t, strings.Contains(r, "**Alice**"), "owner nickname shown")
}

func TestJudgesFixedAtAccept(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "Snapshot table", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	AddMember(cross(cur), tid, judge1, "Judge One")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake + bond}})
	uassert.AbortsWithMessage(t, cur, "opponent is not a member of this table", func() {
		CreateBet(cross(cur), tid, "nobody", "Nobody", stake)
	})
	bid := CreateBet(cross(cur), tid, "snapshot", "BOB", stake)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake + bond}})
	AcceptBet(cross(cur), bid)

	// The owner adds a friend AFTER the bet was accepted: not a judge.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	AddMember(cross(cur), tid, judge2, "Late Friend")

	Report(cross(cur), bid, "a")
	testing.SetRealm(testing.NewUserRealm(bob))
	Report(cross(cur), bid, "b")
	uassert.Equal(t, "disputed", GetBetStatus(bid))

	testing.SetRealm(testing.NewUserRealm(judge2))
	uassert.AbortsWithMessage(t, cur, "you are not a judge on this bet", func() { Vote(cross(cur), bid, "a") })

	testing.SetRealm(testing.NewUserRealm(judge1))
	Vote(cross(cur), bid, "a") // 1 of 1 judges: majority
	uassert.Equal(t, "settled", GetBetStatus(bid))
}

func TestJSON(cur realm, t *testing.T) {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tid := CreateTable(cross(cur), "JSON \"quoted\" table 🍺", "Alice")
	AddMember(cross(cur), tid, bob, "Bob")
	testing.SetOriginSend(chain.Coins{{"ugnot", stake + bond}})
	bid := CreateBet(cross(cur), tid, "json bet", "Bob", stake)

	tj := TableJSON(tid)
	uassert.True(t, strings.Contains(tj, `"name":"JSON \"quoted\" table 🍺"`), "table name escaped: "+tj)
	uassert.True(t, strings.Contains(tj, `"nick":"Bob"`), "members listed")
	bj := BetJSON(bid)
	uassert.True(t, strings.Contains(bj, `"status":"open"`), "bet status: "+bj)
	uassert.True(t, strings.Contains(bj, `"stake":1000000`), "bet stake")
	uassert.True(t, strings.Contains(MyTablesJSON(bob), `"id":`+itoa(tid)), "bob's tables")
	uassert.Equal(t, "[]", MyTablesJSON(outside))

	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "table name has invalid characters", func() { CreateTable(cross(cur), "bad\nname", "x") })
}

func TestRender(cur realm, t *testing.T) {
	uassert.True(t, strings.Contains(Render(""), "How it works"), "home renders")
	uassert.True(t, strings.Contains(Render("table/999"), "Table not found"), "missing table")
	uassert.True(t, strings.Contains(Render("bet/999"), "Bet not found"), "missing bet")
}

