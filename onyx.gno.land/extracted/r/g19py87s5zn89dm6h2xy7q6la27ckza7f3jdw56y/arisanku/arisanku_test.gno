package arisanku

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

// NOTE: testing.SetRealm applies to the frame that calls it, so tests switch
// the caller inline; helpers that need a caller set it and call the realm
// function themselves.

const realmPkg = "gno.land/r/g19py87s5zn89dm6h2xy7q6la27ckza7f3jdw56y/arisanku"

var pkgAddr = chain.PackageAddress(realmPkg)

func balance(a address) int64 {
	return banker.NewReadonlyBanker().GetCoins(a).AmountOf("ugnot")
}

// payAs simulates `gnokey maketx call -send <amount>ugnot ... Pay`: the user
// attaches coins and the chain moves them to the realm before the call.
func payAs(cur realm, a address, id int, amount int64) {
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{{"ugnot", amount}})
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", amount}})
	Pay(cross(cur), id)
}

func settleAs(cur realm, a address, debtID int, amount int64) {
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{{"ugnot", amount}})
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", amount}})
	PayDebt(cross(cur), debtID)
}

func TestGiliranFullLifecycle(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lc-alice")
	bob := testutils.TestAddress("lc-bob")
	cici := testutils.TestAddress("lc-cici")
	const iuran = 1_000_000

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	id := CreateCircle(cross(cur), "Arisan Kantor", "Alice", "1", 3, 60, "giliran")
	c := getCircle(id)
	urequire.True(t, c != nil, "circle created")
	uassert.Equal(t, int(StatusOpen), int(c.Status))
	uassert.Equal(t, int64(iuran), c.Contribution)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "Bob")
	uassert.Equal(t, int(StatusOpen), int(c.Status), "not full yet")
	testing.SetRealm(testing.NewUserRealm(cici))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "")
	uassert.Equal(t, int(StatusRunning), int(c.Status), "auto-start when full")
	uassert.Equal(t, 1, c.Round)

	members := []address{alice, bob, cici}
	for round := 1; round <= 3; round++ {
		for _, m := range members {
			payAs(cur, m, id, iuran)
		}
		uassert.Equal(t, int64(3*iuran), c.Held)
		uassert.Equal(t, c.Held, balance(pkgAddr), "realm holds exactly the pot")
		before := balance(members[round-1])
		testing.SetRealm(testing.NewUserRealm(bob)) // anyone may draw
		testing.SetOriginSend(chain.Coins{})
		w := Draw(cross(cur), id)
		// giliran: join order
		uassert.Equal(t, members[round-1], w, "giliran picks the next in join order")
		uassert.Equal(t, before+3*iuran, balance(w), "winner received the pot")
	}
	uassert.Equal(t, int(StatusFinished), int(c.Status))
	uassert.Equal(t, int64(0), c.Held)
	uassert.Equal(t, int64(0), balance(pkgAddr), "nothing left behind in the realm")
	for i, m := range c.Members {
		uassert.Equal(t, i+1, m.WonRound, "each member won exactly once, in order")
	}
	r := repOf(alice)
	uassert.Equal(t, 3, r.OnTime)
	uassert.Equal(t, 1, r.Wins)
	uassert.Equal(t, int64(3*iuran), r.Contributed)
	uassert.Equal(t, int64(3*iuran), r.Received)
	uassert.Equal(t, 65, TrustScore(alice))

	// finished circle rejects more payments and draws
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", iuran}})
	uassert.AbortsContains(t, cur, "not running", func(cur realm) { Pay(cur, id) })
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsContains(t, cur, "not running", func(cur realm) { Draw(cur, id) })
}

func TestCreateValidation(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("val-creator")))
	cases := []struct {
		name, nick, amount string
		members, period    int
		mode, err          string
	}{
		{"", "", "1", 3, 60, "giliran", "name must be 1 to 40"},
		{"<script>", "", "1", 3, 60, "giliran", "name may only use"},
		{"[x](javascript:alert)", "", "1", 3, 60, "giliran", "name may only use"},
		{"ok", "nick|pipe", "1", 3, 60, "giliran", "nickname may only use"},
		{"ok", "", "0.01", 3, 60, "giliran", "contribution must be between"},
		{"ok", "", "abc", 3, 60, "giliran", "invalid contribution"},
		{"ok", "", "1.1234567", 3, 60, "giliran", "at most 6 decimals"},
		{"ok", "", "1", 1, 60, "giliran", "members must be between"},
		{"ok", "", "1", 13, 60, "giliran", "members must be between"},
		{"ok", "", "1", 3, 0, "giliran", "periodMinutes must be between"},
		{"ok", "", "1", 3, 60, "auction", "mode must be"},
	}
	for _, tc := range cases {
		tc := tc
		uassert.AbortsContains(t, cur, tc.err, func(cur realm) {
			CreateCircle(cur, tc.name, tc.nick, tc.amount, tc.members, tc.period, tc.mode)
		}, tc.name+"/"+tc.amount)
	}
}

func TestJoinLeaveStartCancel(cur realm, t *testing.T) {
	owner := testutils.TestAddress("jl-owner")
	x := testutils.TestAddress("jl-x")
	y := testutils.TestAddress("jl-y")

	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{})
	id := CreateCircle(cross(cur), "Leave Test", "", "0.5", 4, 5, "kocok")
	uassert.AbortsContains(t, cur, "already a member", func(cur realm) { Join(cur, id, "") })
	uassert.AbortsContains(t, cur, "need at least 2", func(cur realm) { Start(cur, id) })
	uassert.AbortsContains(t, cur, "creator cannot leave", func(cur realm) { Leave(cur, id) })

	testing.SetRealm(testing.NewUserRealm(x))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "X")
	uassert.AbortsContains(t, cur, "only the creator can start", func(cur realm) { Start(cur, id) })
	uassert.AbortsContains(t, cur, "only the creator can cancel", func(cur realm) { Cancel(cur, id) })
	Leave(cross(cur), id)
	uassert.Equal(t, 1, len(getCircle(id).Members))
	uassert.AbortsContains(t, cur, "not a member", func(cur realm) { Leave(cur, id) })

	testing.SetRealm(testing.NewUserRealm(y))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "Y")
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{})
	Start(cross(cur), id)
	c := getCircle(id)
	uassert.Equal(t, int(StatusRunning), int(c.Status))
	uassert.Equal(t, 2, c.Size, "size shrinks to members present")
	testing.SetRealm(testing.NewUserRealm(x))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsContains(t, cur, "not open", func(cur realm) { Join(cur, id, "") })

	// cancel a fresh open circle
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{})
	id2 := CreateCircle(cross(cur), "To Cancel", "", "1", 3, 5, "giliran")
	Cancel(cross(cur), id2)
	uassert.Equal(t, int(StatusCancelled), int(getCircle(id2).Status))
	testing.SetRealm(testing.NewUserRealm(x))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsContains(t, cur, "not open", func(cur realm) { Join(cur, id2, "") })
	uassert.AbortsContains(t, cur, "not found", func(cur realm) { Join(cur, 9999, "") })
}

func TestPayGuards(cur realm, t *testing.T) {
	a := testutils.TestAddress("pg-a")
	b := testutils.TestAddress("pg-b")
	stranger := testutils.TestAddress("pg-stranger")
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{})
	id := CreateCircle(cross(cur), "Guards", "", "2", 2, 10, "giliran")

	// cannot pay before the circle runs
	testing.SetOriginSend(chain.Coins{{"ugnot", 2_000_000}})
	uassert.AbortsContains(t, cur, "not running", func(cur realm) { Pay(cur, id) })

	testing.SetRealm(testing.NewUserRealm(b))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "")

	// wrong amounts
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1_999_999}})
	uassert.AbortsContains(t, cur, "attach exactly 2000000ugnot", func(cur realm) { Pay(cur, id) })
	testing.SetOriginSend(chain.Coins{{"ugnot", 2_000_001}})
	uassert.AbortsContains(t, cur, "attach exactly", func(cur realm) { Pay(cur, id) })
	testing.SetOriginSend(chain.Coins{{"ugnot", 2_000_000}, {"foo", 1}})
	uassert.AbortsContains(t, cur, "attach exactly", func(cur realm) { Pay(cur, id) })

	// non-member
	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetOriginSend(chain.Coins{{"ugnot", 2_000_000}})
	uassert.AbortsContains(t, cur, "not a member", func(cur realm) { Pay(cur, id) })

	// draw too early
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsContains(t, cur, "round is still open", func(cur realm) { Draw(cur, id) })

	// double pay
	payAs(cur, a, id, 2_000_000)
	testing.SetOriginSend(chain.Coins{{"ugnot", 2_000_000}})
	uassert.AbortsContains(t, cur, "already paid", func(cur realm) { Pay(cur, id) })
}

// Regression for the OriginSend bypass described in effective-gno: an
// intermediate code realm (or a maketx run script) may keep the coins and
// then call Pay. Pay must refuse anything but a direct user call.
func TestPayRejectsIntermediateRealm(cur realm, t *testing.T) {
	a := testutils.TestAddress("ir-a")
	b := testutils.TestAddress("ir-b")
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{})
	id := CreateCircle(cross(cur), "Bypass", "", "1", 2, 10, "giliran")
	testing.SetRealm(testing.NewUserRealm(b))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "")

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1_000_000}})
	uassert.AbortsContains(t, cur, "must be called directly by a user", func(cur realm) { Pay(cur, id) })
	uassert.AbortsContains(t, cur, "must be called directly by a user", func(cur realm) { PayDebt(cur, 1) })
}

func TestMissedPaymentBecomesDebt(cur realm, t *testing.T) {
	a := testutils.TestAddress("md-a")
	b := testutils.TestAddress("md-b")
	c3 := testutils.TestAddress("md-c")
	family := testutils.TestAddress("md-family")
	const iuran = 1_000_000

	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{})
	id := CreateCircle(cross(cur), "Debt Test", "A", "1", 3, 1, "giliran")
	testing.SetRealm(testing.NewUserRealm(b))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "B")
	testing.SetRealm(testing.NewUserRealm(c3))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "C")
	c := getCircle(id)

	// round 1: only A and B pay, C misses
	payAs(cur, a, id, iuran)
	payAs(cur, b, id, iuran)
	testing.SkipHeights(20) // 100s > 1 minute deadline
	testing.SetRealm(testing.NewUserRealm(b))
	testing.SetOriginSend(chain.Coins{})
	w := Draw(cross(cur), id)
	uassert.Equal(t, a, w)
	uassert.Equal(t, 1, c.Members[2].OpenDebts)
	uassert.Equal(t, 1, repOf(c3).Missed)
	h := c.History[0]
	uassert.Equal(t, int64(2*iuran), h.Pot, "pot is what was actually paid")
	uassert.Equal(t, 1, len(h.Missed))

	debtID := nextDebtID
	d := debts.Get(padID(debtID)).(*Debt)
	uassert.Equal(t, c3, d.Debtor)
	uassert.Equal(t, a, d.Creditor, "debt is owed to the round winner")

	// round 2: everyone pays, B is next in line
	for _, m := range []address{a, b, c3} {
		payAs(cur, m, id, iuran)
	}
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, b, Draw(cross(cur), id))

	// round 3: only C is left but has an open debt -> nobody eligible ->
	// payers refunded, round repeats
	for _, m := range []address{a, b, c3} {
		payAs(cur, m, id, iuran)
	}
	ba, bb, bc := balance(a), balance(b), balance(c3)
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, address(""), Draw(cross(cur), id))
	uassert.True(t, c.History[len(c.History)-1].Refunded)
	uassert.Equal(t, 3, c.Round, "round repeats")
	uassert.Equal(t, ba+iuran, balance(a))
	uassert.Equal(t, bb+iuran, balance(b))
	uassert.Equal(t, bc+iuran, balance(c3))
	uassert.Equal(t, int(StatusRunning), int(c.Status))

	// family settles C's debt; money goes straight to the creditor (A)
	testing.SetRealm(testing.NewUserRealm(family))
	testing.SetOriginSend(chain.Coins{{"ugnot", 999}})
	uassert.AbortsContains(t, cur, "attach exactly", func(cur realm) { PayDebt(cur, debtID) })
	before := balance(a)
	settleAs(cur, family, debtID, iuran)
	uassert.Equal(t, before+iuran, balance(a))
	uassert.True(t, d.Settled)
	uassert.Equal(t, family, d.SettledBy)
	uassert.Equal(t, 0, c.Members[2].OpenDebts)
	uassert.Equal(t, 1, repOf(c3).Settled)
	testing.SetOriginSend(chain.Coins{{"ugnot", iuran}})
	uassert.AbortsContains(t, cur, "already settled", func(cur realm) { PayDebt(cur, debtID) })
	uassert.AbortsContains(t, cur, "debt not found", func(cur realm) { PayDebt(cur, 424242) })

	// now C can win round 3
	for _, m := range []address{a, b, c3} {
		payAs(cur, m, id, iuran)
	}
	testing.SetRealm(testing.NewUserRealm(c3))
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, c3, Draw(cross(cur), id))
	uassert.Equal(t, int(StatusFinished), int(c.Status))
	uassert.Equal(t, int64(0), balance(pkgAddr), "solvent: refunds, pots and debts all paid out")
}

func TestKocokEveryoneWinsOnce(cur realm, t *testing.T) {
	names := []string{"k-1", "k-2", "k-3", "k-4", "k-5"}
	var addrs []address
	for _, n := range names {
		addrs = append(addrs, testutils.TestAddress(n))
	}
	testing.SetRealm(testing.NewUserRealm(addrs[0]))
	testing.SetOriginSend(chain.Coins{})
	id := CreateCircle(cross(cur), "Kocok Five", "", "0.25", 5, 30, "kocok")
	for _, a := range addrs[1:] {
		testing.SetRealm(testing.NewUserRealm(a))
		testing.SetOriginSend(chain.Coins{})
		Join(cross(cur), id, "")
	}
	seen := map[string]bool{}
	for round := 0; round < 5; round++ {
		for _, a := range addrs {
			payAs(cur, a, id, 250_000)
		}
		testing.SkipHeights(1)
		testing.SetRealm(testing.NewUserRealm(addrs[0]))
		testing.SetOriginSend(chain.Coins{})
		w := Draw(cross(cur), id)
		urequire.False(t, seen[w.String()], "nobody wins twice")
		seen[w.String()] = true
	}
	uassert.Equal(t, 5, len(seen))
	uassert.Equal(t, int(StatusFinished), int(getCircle(id).Status))
}

func TestParseGNOT(t *testing.T) {
	ok := map[string]int64{"1": 1_000_000, "0.5": 500_000, ".25": 250_000, "2.000001": 2_000_001, " 3 GNOT ": 3_000_000, "10": 10_000_000}
	for in, want := range ok {
		got, err := parseGNOT(in)
		if err != "" || got != want {
			t.Errorf("parseGNOT(%q) = %d,%q want %d", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "-1", "1e6", "1.2.3", "abc", "1.0000001", "1234567890"} {
		if _, err := parseGNOT(bad); err == "" {
			t.Errorf("parseGNOT(%q) should fail", bad)
		}
	}
}

func TestRenderAndJSON(cur realm, t *testing.T) {
	a := testutils.TestAddress("rd-a")
	b := testutils.TestAddress("rd-b")
	testing.SetRealm(testing.NewUserRealm(a))
	testing.SetOriginSend(chain.Coins{})
	id := CreateCircle(cross(cur), "Arisan RT 09", "Rizki", "1", 2, 10080, "kocok")
	home := Render("")
	uassert.True(t, strings.Contains(home, "ArisanKu"))
	uassert.True(t, strings.Contains(home, "Arisan RT 09"))
	uassert.True(t, strings.Contains(home, "$help&func=Join"))

	testing.SetRealm(testing.NewUserRealm(b))
	testing.SetOriginSend(chain.Coins{})
	Join(cross(cur), id, "Ayu")
	page := Render("circle/" + strconv.Itoa(id))
	uassert.True(t, strings.Contains(page, "data:image/svg+xml;base64,"), "wheel svg")
	uassert.True(t, strings.Contains(page, "Rizki"))
	uassert.True(t, strings.Contains(page, "1 week"))
	uassert.True(t, strings.Contains(page, ".send=1000000ugnot"), "pay button carries the exact send")
	uassert.True(t, strings.Contains(page, "Waiting for payments"))

	uassert.True(t, strings.Contains(Render("member/"+a.String()), "trust score"))
	uassert.True(t, strings.Contains(Render("new"), `<gno-form exec="CreateCircle">`))
	uassert.True(t, strings.Contains(Render("how"), "Fair by construction"))
	uassert.True(t, strings.Contains(Render("nope/x/y"), "404"))
	uassert.True(t, strings.Contains(Render("circle/abc"), "404"))
	uassert.True(t, strings.Contains(Render("member/notanaddress"), "Invalid address"))

	js := CircleJSON(id)
	uassert.True(t, strings.HasPrefix(js, `{"id":`+strconv.Itoa(id)+`,"name":"Arisan RT 09","status":"running","mode":"kocok"`), js)
	uassert.True(t, strings.Contains(js, `"nick":"Ayu"`))
	uassert.Equal(t, "null", CircleJSON(987654))
	uassert.True(t, CircleCount() >= id)
}

