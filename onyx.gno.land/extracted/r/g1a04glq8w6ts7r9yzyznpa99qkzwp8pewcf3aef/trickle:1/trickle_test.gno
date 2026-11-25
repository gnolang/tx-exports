package trickle

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")

	realmAddr = chain.PackageAddress("gno.land/r/g1a04glq8w6ts7r9yzyznpa99qkzwp8pewcf3aef/trickle")
)

// send attaches ugnot to the next call the way the chain does: the coins
// land at the realm address before the function runs. testing.SetRealm only
// affects the frame that calls it, so each test sets the caller itself.
func send(addr address, ugnot int64) {
	testing.SetOriginCaller(addr)
	if ugnot > 0 {
		coins := chain.NewCoins(chain.NewCoin("ugnot", ugnot))
		testing.SetOriginSend(coins)
		testing.IssueCoins(realmAddr, coins)
	} else {
		testing.SetOriginSend(nil)
	}
}

func setTime(unix int64) {
	ctx := testing.GetContext()
	ctx.Time = time.Unix(unix, 0)
	testing.SetContext(ctx)
}

func balance(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, "ugnot")
}

func TestLifecycle(cur realm, t *testing.T) {
	setTime(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 1_000_000)
	id := Create(cross(cur), bob, 0, 0, 1000, true, "salary")
	uassert.Equal(t, int64(0), Withdrawable(id))

	setTime(1_000_250)
	uassert.Equal(t, int64(250_000), Withdrawable(id))

	// Only the recipient withdraws.
	testing.SetRealm(testing.NewUserRealm(carol))
	send(carol, 0)
	uassert.AbortsContains(t, cur, "only the recipient", func() { Withdraw(cross(cur), id, 0) })

	before := balance(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	send(bob, 0)
	uassert.Equal(t, int64(100_000), Withdraw(cross(cur), id, 100_000))
	uassert.Equal(t, int64(150_000), Withdraw(cross(cur), id, 0))
	uassert.Equal(t, before+250_000, balance(bob))
	uassert.AbortsContains(t, cur, "nothing to withdraw", func() { Withdraw(cross(cur), id, 0) })

	// Sender cancels at 60%: recipient gets the unclaimed 35%, sender 40%.
	setTime(1_000_600)
	aliceBefore, bobBefore := balance(alice), balance(bob)
	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 0)
	Cancel(cross(cur), id)
	uassert.Equal(t, aliceBefore+400_000, balance(alice))
	uassert.Equal(t, bobBefore+350_000, balance(bob))
	uassert.AbortsContains(t, cur, "already canceled", func() { Cancel(cross(cur), id) })
	uassert.True(t, strings.Contains(StreamJSON(id), `"status":"canceled"`))
}

func TestCliffAndFullWithdraw(cur realm, t *testing.T) {
	setTime(2_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 500)
	id := Create(cross(cur), bob, 2_000_100, 50, 100, false, "")

	setTime(2_000_149)
	uassert.Equal(t, int64(0), Withdrawable(id))
	setTime(2_000_150)
	uassert.Equal(t, int64(250), Withdrawable(id))

	// Non-cancelable: the sender is locked in.
	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 0)
	uassert.AbortsContains(t, cur, "not cancelable", func() { Cancel(cross(cur), id) })

	setTime(2_000_999)
	testing.SetRealm(testing.NewUserRealm(bob))
	send(bob, 0)
	uassert.Equal(t, int64(500), Withdraw(cross(cur), id, 0))
	uassert.True(t, strings.Contains(StreamJSON(id), `"status":"settled"`))
	uassert.AbortsContains(t, cur, "fully vested", func() { Cancel(cross(cur), id) })
}

func TestTransfer(cur realm, t *testing.T) {
	setTime(3_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 1000)
	id := Create(cross(cur), bob, 0, 0, 100, true, "")

	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 0)
	uassert.AbortsContains(t, cur, "only the recipient", func() { Transfer(cross(cur), id, carol) })
	testing.SetRealm(testing.NewUserRealm(bob))
	send(bob, 0)
	uassert.AbortsContains(t, cur, "must differ", func() { Transfer(cross(cur), id, alice) })
	Transfer(cross(cur), id, carol)

	setTime(3_000_050)
	uassert.AbortsContains(t, cur, "only the recipient", func() { Withdraw(cross(cur), id, 0) })
	testing.SetRealm(testing.NewUserRealm(carol))
	send(carol, 0)
	uassert.Equal(t, int64(500), Withdraw(cross(cur), id, 0))

	uassert.True(t, strings.Contains(IncomingJSON(carol, 0, 10), `"deposit":1000`))
	uassert.False(t, strings.Contains(IncomingJSON(bob, 0, 10), `"deposit":1000,`))

	// A fully unlocked stream with unclaimed funds can still be handed over.
	setTime(3_000_200)
	Transfer(cross(cur), id, bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	send(bob, 0)
	uassert.Equal(t, int64(500), Withdraw(cross(cur), id, 0))
	uassert.AbortsContains(t, cur, "finished", func() { Transfer(cross(cur), id, carol) })
}

func TestCreateBatch(cur realm, t *testing.T) {
	setTime(4_000_000)
	list := bob.String() + ":300, " + carol.String() + ":700"

	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 999)
	uassert.AbortsContains(t, cur, "more than", func() { CreateBatch(cross(cur), list, 0, 0, 100, true, "payroll") })
	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 1001)
	uassert.AbortsContains(t, cur, "less than", func() { CreateBatch(cross(cur), list, 0, 0, 100, true, "payroll") })

	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 1000)
	n := Count()
	ids := CreateBatch(cross(cur), list, 0, 0, 100, true, "payroll")
	uassert.Equal(t, n+2, Count())
	uassert.Equal(t, 2, len(strings.Split(ids, ",")))

	setTime(4_000_100)
	testing.SetRealm(testing.NewUserRealm(carol))
	send(carol, 0)
	uassert.Equal(t, int64(700), Withdraw(cross(cur), uint64(Count()), 0))
}

func TestCreateValidation(cur realm, t *testing.T) {
	setTime(5_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 0)
	uassert.AbortsContains(t, cur, "send ugnot", func() { Create(cross(cur), bob, 0, 0, 100, true, "") })

	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 100)
	uassert.AbortsContains(t, cur, "in the past", func() { Create(cross(cur), bob, 4_999_999, 0, 100, true, "") })
	uassert.AbortsContains(t, cur, "cliffSeconds", func() { Create(cross(cur), bob, 0, 200, 100, true, "") })
	uassert.AbortsContains(t, cur, "cliffSeconds", func() { Create(cross(cur), bob, 0, 0, 0, true, "") })
	uassert.AbortsContains(t, cur, "must differ", func() { Create(cross(cur), alice, 0, 0, 100, true, "") })
	uassert.AbortsContains(t, cur, "invalid address", func() { Create(cross(cur), address("g1nope"), 0, 0, 100, true, "") })
	// A valid but non-canonical spelling could never be withdrawn from.
	uassert.AbortsContains(t, cur, "invalid address", func() {
		Create(cross(cur), address(strings.ToUpper(bob.String())), 0, 0, 100, true, "")
	})
	uassert.AbortsContains(t, cur, "control characters", func() { Create(cross(cur), bob, 0, 0, 100, true, "a\nb") })
	uassert.AbortsContains(t, cur, "memo", func() { Create(cross(cur), bob, 0, 0, 100, true, strings.Repeat("x", 81)) })
}

// A realm sitting between the user and Create could keep the attached
// coins; Create must refuse to credit a deposit it may not have received.
func TestCreateRejectsIntermediaries(cur realm, t *testing.T) {
	setTime(6_000_000)
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	uassert.AbortsContains(t, cur, "directly by a user", func() { Create(cross(cur), bob, 0, 0, 100, true, "") })
}

// The realm must always hold exactly what it still owes. Earlier tests
// issue coins for calls that abort (on chain those transactions revert), so
// this compares against the surplus at entry.
func TestSolvency(cur realm, t *testing.T) {
	surplus := func() int64 {
		return balance(realmAddr) - (totalDeposited - totalPaid - totalRefunded)
	}
	base := surplus()

	setTime(6_500_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 1_000_003)
	a := Create(cross(cur), bob, 0, 0, 7, true, "")
	send(alice, 999_999)
	b := Create(cross(cur), carol, 0, 3, 11, true, "")
	uassert.Equal(t, base, surplus())

	for now := int64(6_500_001); now < 6_500_006; now++ {
		setTime(now)
		testing.SetRealm(testing.NewUserRealm(bob))
		send(bob, 0)
		Withdraw(cross(cur), a, 0)
		uassert.Equal(t, base, surplus())
	}
	testing.SetRealm(testing.NewUserRealm(carol))
	send(carol, 0)
	Cancel(cross(cur), b)
	uassert.Equal(t, base, surplus())

	setTime(6_500_100)
	testing.SetRealm(testing.NewUserRealm(bob))
	send(bob, 0)
	Withdraw(cross(cur), a, 0)
	uassert.Equal(t, base, surplus())
}

func TestRender(cur realm, t *testing.T) {
	setTime(7_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	send(alice, 2_500_000)
	id := Create(cross(cur), bob, 0, 0, 100, true, "rent | [x](http://evil) <b>")
	setTime(7_000_050)

	home := Render("")
	uassert.True(t, strings.Contains(home, "# Trickle"))
	uassert.True(t, strings.Contains(home, "2.5 GNOT"))
	uassert.False(t, strings.Contains(home, "](http://evil)"))

	page := Render("stream/" + itoa(id))
	uassert.True(t, strings.Contains(page, "50.0%"))
	uassert.True(t, strings.Contains(page, "████████████░░░░░░░░░░░░"))
	uassert.False(t, strings.Contains(page, "](http://evil)"))

	uassert.True(t, strings.Contains(Render("account/"+bob.String()), "## Incoming"))
	older := Render("account/" + bob.String() + "/2")
	uassert.True(t, strings.Contains(older, "[Newer]("))
	uassert.False(t, strings.Contains(older, "[Older]("))
	uassert.True(t, strings.Contains(Render("account/"+bob.String()+"/0"), "Not found"))
	uassert.True(t, strings.Contains(Render("account/"+bob.String()+"/x"), "Not found"))
	uassert.True(t, strings.Contains(Render("stream/999999"), "Not found"))
	uassert.True(t, strings.Contains(Render("account/<script>"), "Not found"))
	uassert.True(t, strings.Contains(Render("nope"), "Not found"))
}

func TestFormatting(t *testing.T) {
	uassert.Equal(t, "0 GNOT", gnot(0))
	uassert.Equal(t, "1 GNOT", gnot(1_000_000))
	uassert.Equal(t, "0.000001 GNOT", gnot(1))
	uassert.Equal(t, "12.34 GNOT", gnot(12_340_000))
	uassert.Equal(t, `"a\"b\\c"`, jsonString(`a"b\c`))
}

func itoa(id uint64) string {
	s := ""
	for id > 0 {
		s = string(rune('0'+id%10)) + s
		id /= 10
	}
	return s
}
