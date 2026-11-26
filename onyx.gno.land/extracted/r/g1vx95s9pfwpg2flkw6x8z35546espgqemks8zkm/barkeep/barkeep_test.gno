package barkeep

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/g1vx95s9pfwpg2flkw6x8z35546espgqemks8zkm/bounty/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	alice    = testutils.TestAddress("alice") // poster
	bob      = testutils.TestAddress("bob")   // hunter
	carol    = testutils.TestAddress("carol") // bystander
	realmAdr = chain.PackageAddress("gno.land/r/g1vx95s9pfwpg2flkw6x8z35546espgqemks8zkm/barkeep")
)

func reset() {
	board = bounty.NewBoard(board.Config())
}

func ugnot(n int64) chain.Coins { return chain.Coins{{"ugnot", n}} }

func balance(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoins(addr).AmountOf("ugnot")
}

// postAs simulates a wallet call to Post with coins attached: the chain
// moves the coins to the realm before the call, so the test issues them.
func postAs(cur realm, addr address, reward int64, title string) uint64 {
	testing.IssueCoins(realmAdr, ugnot(reward))
	testing.SetRealm(testing.NewUserRealm(addr))
	testing.SetOriginSend(ugnot(reward))
	return Post(cross(cur), title, "Some details", 24)
}

func TestPostAndPay(cur realm, t *testing.T) {
	reset()
	id := postAs(cur, alice, 5_000_000, "Translate the README")
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, int64(5_000_000), Escrowed())

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://github.com/example/pr/1")

	// only the poster may approve
	uassert.AbortsContains(t, cur, "only the poster", func() { Approve(cross(cur), id) })

	before := balance(bob)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Approve(cross(cur), id)
	uassert.Equal(t, before+5_000_000, balance(bob))
	uassert.Equal(t, int64(0), Escrowed())

	_, _, _, status, hunter := GetBounty(id)
	uassert.Equal(t, "paid", status)
	uassert.Equal(t, bob, hunter)

	completed, earned, score := Reputation(bob)
	uassert.Equal(t, 1, completed)
	uassert.Equal(t, int64(5_000_000), earned)
	uassert.Equal(t, 10, score)
}

func TestPostValidation(cur realm, t *testing.T) {
	reset()
	// no coins attached
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "attach the reward", func() { Post(cross(cur), "x", "", 24) })

	// wrong denom
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ufoo", 5_000_000}})
	uassert.AbortsContains(t, cur, "only ugnot", func() { Post(cross(cur), "x", "", 24) })

	// below minimum
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(10))
	uassert.AbortsContains(t, cur, "below the board minimum", func() { Post(cross(cur), "x", "", 24) })

	// bad claim window
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(5_000_000))
	uassert.AbortsContains(t, cur, "claim window", func() { Post(cross(cur), "x", "", 0) })

	// coins sent to a non-payable function
	id := postAs(cur, alice, 2_000_000, "ok")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnot(1))
	uassert.AbortsContains(t, cur, "does not take coins", func() { Claim(cross(cur), id) })
}

func TestCancelRefunds(cur realm, t *testing.T) {
	reset()
	id := postAs(cur, alice, 3_000_000, "Draw a gnome")

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "only the poster", func() { Cancel(cross(cur), id) })

	before := balance(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Cancel(cross(cur), id)
	uassert.Equal(t, before+3_000_000, balance(alice))
	uassert.Equal(t, int64(0), Escrowed())
}

func TestRejectAndReclaim(cur realm, t *testing.T) {
	reset()
	id := postAs(cur, alice, 2_000_000, "Write a test")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "not really")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Reject(cross(cur), id, "please add tests")
	_, _, _, status, _ := GetBounty(id)
	uassert.Equal(t, "open", status)

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	_, _, _, status, hunter := GetBounty(id)
	uassert.Equal(t, "claimed", status)
	uassert.Equal(t, carol, hunter)
}

func TestCollectWhenPosterGhosts(cur realm, t *testing.T) {
	reset()
	id := postAs(cur, alice, 4_000_000, "Fix a bug")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://example.com/fix")

	uassert.AbortsContains(t, cur, "review window", func() { Collect(cross(cur), id) })

	skip(73 * time.Hour)
	before := balance(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Collect(cross(cur), id)
	uassert.Equal(t, before+4_000_000, balance(bob))
}

func TestReleaseExpiredClaim(cur realm, t *testing.T) {
	reset()
	id := postAs(cur, alice, 1_000_000, "Quick task")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "not expired", func() { Release(cross(cur), id) })

	skip(25 * time.Hour)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	Release(cross(cur), id)
	_, _, _, status, _ := GetBounty(id)
	uassert.Equal(t, "open", status)
}

func TestRender(cur realm, t *testing.T) {
	reset()
	id := postAs(cur, alice, 1_500_000, "Brew *strong* coffee [x](javascript:alert(1))")

	home := Render("")
	uassert.True(t, strings.Contains(home, "Barkeep"), "header")
	uassert.True(t, strings.Contains(home, "1.5 GNOT"), "reward formatting")
	uassert.True(t, strings.Contains(home, "Pin a new bounty"), "post button")
	uassert.False(t, strings.Contains(home, "](javascript"), "title must be sanitized")

	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "Claim this bounty"), "claim action")
	uassert.True(t, strings.Contains(detail, "func=Claim"), "tx link")

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://example.com/coffee")
	detail = Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "Approve & pay"), "approve action")
	uassert.True(t, strings.Contains(detail, "(https://example.com/coffee)"), "proof link")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Approve(cross(cur), id)
	uassert.True(t, strings.Contains(Render("hunters"), "🥇"), "leaderboard")
	uassert.True(t, strings.Contains(Render("u/"+bob.String()), "Completed | 1"), "profile")
	uassert.True(t, strings.Contains(Render("status/paid"), "#1"), "filter")
	uassert.True(t, strings.Contains(Render("bounty/99"), "No bounty"), "missing")
	uassert.True(t, strings.Contains(Render("help"), "How the tavern works"), "help")

	urequire.True(t, strings.Contains(Render("nope/nope/nope"), "Nothing pinned"), "404")
}

func TestGnotFormat(t *testing.T) {
	uassert.Equal(t, "1 GNOT", gnot(1_000_000))
	uassert.Equal(t, "1.5 GNOT", gnot(1_500_000))
	uassert.Equal(t, "0.000001 GNOT", gnot(1))
	uassert.Equal(t, "12.34 GNOT", gnot(12_340_000))
}

// skip advances the block clock. SkipHeights resets the realm context,
// so callers must set the caller again afterwards.
func skip(d time.Duration) {
	testing.SkipHeights(int64(d/(5*time.Second)) + 1)
}
