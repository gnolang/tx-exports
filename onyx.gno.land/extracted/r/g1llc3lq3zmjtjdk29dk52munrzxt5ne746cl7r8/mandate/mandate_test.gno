package mandate

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// Test notes
//
// Sessions: `gno test` cannot sign with a session key, so
// runtime.GetSessionInfo() always reports "not a session" here. Pull's rules
// live in checkPull and recordPull, which take the session info as plain
// arguments and are tested directly below. The real session path (signing,
// spend limits, revoke, expiry, the transfer) is proven on a real chain by
// scripts/local-flow.sh.
//
// Reverts: the test harness does not roll back realm state when a call
// panics; on chain the whole transaction reverts. So every refused call is
// checked to leave all state and the realm balance unchanged, which holds
// because every check runs before the first write.
//
// Time: testing.SkipHeights(n) moves the block time by 5*n seconds.

var (
	payee    = testutils.TestAddress("md_payee")
	payee2   = testutils.TestAddress("md_payee2")
	payer    = testutils.TestAddress("md_payer")
	payer2   = testutils.TestAddress("md_payer2")
	stranger = testutils.TestAddress("md_stranger")

	realmAddr = chain.PackageAddress("gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate")
)

// Two real session keys and the addresses the chain derives from them
// (taken from a local chain: gnokey list).
const (
	gpubA = "gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqfp0696ldln2nm7kd33zfpgypg6u0e7upl03hyeexa6mccn4ce8mkswg65c"
	sessA = address("g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh")
	gpubB = "gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqtwu0rahac8cw2fw7fmlan472nfyprlgdp4c034vmwyumy4yksl67587x7p"
	sessB = address("g1valkxsym77y3qlj5fq9h4p64y73l3masvuxav0")

	selfPaths = "vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
	gnot      = int64(1_000_000)
	day       = int64(86400)
)

func ugnot(n int64) chain.Coins { return chain.Coins{{Denom: "ugnot", Amount: n}} }

func bal(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, "ugnot") }

func now() int64 { return time.Now().Unix() }

func resetState() {
	nextPlanID, nextMandateID = 0, 0
	plans, payees, payers = avl.NewTree(), avl.NewTree(), avl.NewTree()
	pullLog = nil
	totalPulls, totalPaid = 0, 0
}

// testing.SetRealm changes the realm of the frame that calls it, so it is
// called inline right before each cross(cur) call it is meant for.

func offer(cur realm, who address, title string, amount, period int64) uint64 {
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(who))
	return Offer(cross(cur), title, amount, period)
}

func setKey(cur realm, who address, gpub string) {
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(who))
	SetCollectorKey(cross(cur), gpub)
}

func subscribe(cur realm, who address, planID uint64, sess address, expires int64) uint64 {
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(who))
	return Subscribe(cross(cur), planID, sess, expires)
}

func cancel(cur realm, who, p, sess address) {
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(who))
	Cancel(cross(cur), p, sess)
}

// pullOK runs Pull's rules and state update as the chain would for a
// correct session-signed call (the transfer itself is proven by the local
// flow script).
func pullOK(p address, sess address, amount int64) {
	m, pl := checkPull(true, sess, []string{selfPaths}, p, ugnot(amount), now())
	recordPull(m, pl, now())
	pullLog = append(pullLog, pulled{plan: pl.ID, at: now()})
}

// pullLog records every payment the tests make, so expected per-period
// counts are computed independently of the realm's counters.
type pulled struct {
	plan uint64
	at   int64
}

var pullLog []pulled

// expectedWindows counts the logged payments of a plan in the period window
// containing now and in the one before.
func expectedWindows(planID uint64, period int64) (current, previous int) {
	w := now() / period
	for _, x := range pullLog {
		if x.plan != planID {
			continue
		}
		switch x.at / period {
		case w:
			current++
		case w - 1:
			previous++
		}
	}
	return
}

// snapshot is everything a refused call must leave unchanged.
func snapshot() string {
	var b strings.Builder
	n1, n2, pulls, paid := Totals()
	b.WriteString(itoa(int64(n1)) + "/" + itoa(int64(n2)) + "/" + itoa(pulls) + "/" + itoa(paid) + "/" + itoa(bal(realmAddr)) + "\n")
	mandate := func(m *Mandate) {
		b.WriteString(utoa(m.ID) + m.Payer.String() + m.Session.String() + itoa(m.ExpiresAt) + itoa(m.NextPullAt) +
			itoa(m.Pulls) + itoa(m.CancelledAt) + m.CancelledBy.String() + "\n")
	}
	plans.Iterate("", "", func(_ string, v any) bool {
		p := v.(*Plan)
		b.WriteString(p.Title + itoa(p.Amount) + itoa(p.Period) + itoa(int64(p.Supporters.N)) + "c" + itoa(int64(p.Cancelled)) + "w" + itoa(p.payWindow) + "/" + itoa(int64(p.paidThis)) + "/" + itoa(int64(p.paidPrev)) +
			itoa(p.Pulls) + itoa(p.LastPullAt) + "\n")
		for i := 0; i < p.Supporters.N; i++ {
			b.WriteString(p.Supporters.at(i) + ",")
		}
		return false
	})
	payees.Iterate("", "", func(k string, v any) bool {
		pe := v.(*Payee)
		b.WriteString(k + itoa(int64(pe.Plans)) + itoa(pe.Pulls) + itoa(pe.Paid) + pe.CollectorKey + pe.CollectorAddr.String() + "\n")
		return false
	})
	payers.Iterate("", "", func(k string, v any) bool {
		pr := v.(Payer)
		b.WriteString("\npayer " + k + " active:")
		for _, r := range pr.Active {
			b.WriteString(" " + r.Session.String() + "/" + utoa(r.PlanID) + "=" + utoa(r.M.ID))
		}
		if pr.Head != nil {
			b.WriteString(" head=" + utoa(pr.Head.ID))
		}
		for m := pr.Head; m != nil; m = m.prevOfPayer {
			mandate(m)
		}
		return false
	})
	for _, t := range []*avl.Tree{plans, payees, payers} {
		b.WriteString(itoa(int64(t.Size())) + ",")
	}
	return b.String()
}

// fails asserts fn aborts with a message containing substr and changes nothing.
func fails(t *testing.T, rlm realm, substr string, fn func(), what string) {
	t.Helper()
	before := snapshot()
	uassert.AbortsContains(t, rlm, substr, fn, what)
	if after := snapshot(); after != before {
		t.Fatalf("%s: state changed by a refused call\nbefore:\n%s\nafter:\n%s", what, before, after)
	}
}

// panicsLocal is fails for non-crossing helpers (checkPull).
func panicsLocal(t *testing.T, rlm realm, substr string, fn func(), what string) {
	t.Helper()
	before := snapshot()
	uassert.PanicsContains(t, rlm, substr, fn, what)
	if after := snapshot(); after != before {
		t.Fatalf("%s: state changed by a refused pull", what)
	}
}

func TestOffer(cur realm, t *testing.T) {
	resetState()
	id := offer(cur, payee, "Weekly supporter", gnot, 7*day)
	uassert.Equal(t, uint64(1), id)
	p, ok := GetPlan(id)
	uassert.True(t, ok)
	uassert.Equal(t, payee.String(), p.Payee.String())
	uassert.Equal(t, "Weekly supporter", p.Title)
	uassert.Equal(t, gnot, p.Amount)
	uassert.Equal(t, 7*day, p.Period)
	uassert.Equal(t, now(), p.CreatedAt)
	pe, ok := GetPayee(payee)
	uassert.True(t, ok)
	uassert.Equal(t, 1, pe.Plans)
	uassert.Equal(t, int64(0), bal(realmAddr))

	// Boundaries are accepted.
	offer(cur, payee, "min", MinAmount, MinPeriod)
	offer(cur, payee, "max", MaxAmount, MaxPeriod)
	offer(cur, payee, strings.Repeat("é", MaxTitleLen), gnot, day)
	uassert.Equal(t, uint64(4), nextPlanID)
	uassert.Equal(t, 4, payeeOf(payee).Plans)
}

func TestOfferRefusals(cur realm, t *testing.T) {
	resetState()
	offer(cur, payee, "existing", gnot, day)
	cases := []struct {
		title          string
		amount, period int64
		want           string
	}{
		{"", gnot, day, "title is empty"},
		{"   ", gnot, day, "title is empty"},
		{strings.Repeat("a", MaxTitleLen+1), gnot, day, "longer than 80"},
		{"two\nlines", gnot, day, "single line"},
		{"tab\there", gnot, day, "single line"},
		{"cr\rhere", gnot, day, "single line"},
		{"nul\x00here", gnot, day, "single line"},
		{"sep\u2028here", gnot, day, "single line"},
		{"sep\u2029here", gnot, day, "single line"},
		{"del\x7fhere", gnot, day, "single line"},
		{"zero\u200bwidth", gnot, day, "invisible formatting"},
		{"Fluxen\u202egnp.exe", gnot, day, "invisible formatting"},
		{"\ufeffbom", gnot, day, "invisible formatting"},
		{"iso\u2066late\u2069", gnot, day, "invisible formatting"},
		{"soft\u00adhyphen", gnot, day, "invisible formatting"},
		{"joiner\u200d", gnot, day, "invisible formatting"},
		{"bad\xffutf8", gnot, day, "not valid UTF-8"},
		{"ok", MinAmount - 1, day, "below the minimum"},
		{"ok", 0, day, "below the minimum"},
		{"ok", -gnot, day, "below the minimum"},
		{"ok", MaxAmount + 1, day, "above the maximum"},
		{"ok", gnot, MinPeriod - 1, "period is below"},
		{"ok", gnot, 0, "period is below"},
		{"ok", gnot, -1, "period is below"},
		{"ok", gnot, MaxPeriod + 1, "period is above"},
	}
	for _, c := range cases {
		testing.SetOriginSend(nil)
		testing.SetRealm(testing.NewUserRealm(payee))
		fails(t, cur, c.want, func() { Offer(cross(cur), c.title, c.amount, c.period) }, "Offer "+c.want)
	}

	// Coins attached are refused (the realm never holds funds).
	testing.SetRealm(testing.NewUserRealm(payee))
	testing.SetOriginSend(ugnot(gnot))
	fails(t, cur, "do not send coins", func() { Offer(cross(cur), "ok", gnot, day) }, "Offer with coins")
	testing.SetOriginSend(nil)

	// Only direct calls from a user.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/someone/proxy"))
	fails(t, cur, "direct calls only", func() { Offer(cross(cur), "ok", gnot, day) }, "Offer from a realm")
}

func TestTitleCharacters(cur realm, t *testing.T) {
	resetState()
	// Visible non-ASCII text is fine; only invisible formatting is refused.
	for _, title := range []string{"Café ☕ für alle", "Support Fluxen's work", "日本語のプラン", "Ünïcödé — dash"} {
		id := offer(cur, payee, title, gnot, day)
		p, _ := GetPlan(id)
		uassert.Equal(t, title, p.Title)
	}
}

// PaidThrough moves only with a successful payment: never before the first
// one, payment time + period after each, and the paid time is kept after a
// cancel until it runs out. IsPaidUp is now < PaidThrough, exclusive at the boundary.
func TestPaidThrough(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Plan", gnot, MinPeriod)
	uassert.Equal(t, int64(0), PaidThrough(payer, pid))
	subscribe(cur, payer, pid, sessA, now()+600)
	uassert.True(t, HasMandate(payer, pid))
	uassert.Equal(t, int64(0), PaidThrough(payer, pid), "recorded, not paid")
	uassert.False(t, IsPaidUp(payer, pid))

	t0 := now()
	pullOK(payer, sessA, gnot)
	uassert.Equal(t, t0+MinPeriod, PaidThrough(payer, pid))
	uassert.True(t, IsPaidUp(payer, pid))
	uassert.Equal(t, int64(0), PaidThrough(payer2, pid), "another payer")
	uassert.Equal(t, int64(0), PaidThrough(payer, pid+1), "another plan")

	testing.SkipHeights(MinPeriod/5 - 1) // one block before the period ends
	uassert.True(t, IsPaidUp(payer, pid))
	testing.SkipHeights(1) // now == PaidThrough
	uassert.False(t, IsPaidUp(payer, pid), "exclusive at the boundary")
	uassert.Equal(t, t0+MinPeriod, PaidThrough(payer, pid), "unchanged without a payment")
	uassert.True(t, HasMandate(payer, pid), "a mandate is not a payment")

	t1 := now()
	pullOK(payer, sessA, gnot)
	uassert.Equal(t, t1+MinPeriod, PaidThrough(payer, pid))

	cancel(cur, payer, payer, sessA)
	uassert.Equal(t, t1+MinPeriod, PaidThrough(payer, pid), "cancelled: the paid period is still the payer's")
	uassert.True(t, IsPaidUp(payer, pid))
	uassert.False(t, HasMandate(payer, pid))
	testing.SkipHeights(MinPeriod / 5)
	uassert.False(t, IsPaidUp(payer, pid), "the kept time runs out")
}

func TestSetCollectorKey(cur realm, t *testing.T) {
	resetState()
	// Allowed before any plan: it creates the payee record.
	setKey(cur, payee, gpubA)
	pe, ok := GetPayee(payee)
	uassert.True(t, ok)
	uassert.Equal(t, gpubA, pe.CollectorKey)
	uassert.Equal(t, sessA.String(), pe.CollectorAddr.String())
	uassert.Equal(t, 0, pe.Plans)
	// Replace it.
	setKey(cur, payee, gpubB)
	uassert.Equal(t, sessB.String(), payeeOf(payee).CollectorAddr.String())

	for _, c := range []struct{ key, want string }{
		{"", "must be a bech32 public key"},
		{"g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh", "must be a bech32 public key"},
		{"gpub1" + strings.Repeat("q", 200), "must be a bech32 public key"},
		{gpubA[:len(gpubA)-1] + "q", "not a valid public key"}, // bad checksum
		{"gpub1mdgqmw", "not a valid public key"},
		{"gpub1qqqqqq", "not a valid public key"},
	} {
		testing.SetOriginSend(nil)
		testing.SetRealm(testing.NewUserRealm(payee))
		fails(t, cur, c.want, func() { SetCollectorKey(cross(cur), c.key) }, "SetCollectorKey "+c.key)
	}
	// The payee's own main key is refused.
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(sessA))
	fails(t, cur, "dedicated key", func() { SetCollectorKey(cross(cur), gpubA) }, "own key as collector")
	testing.SetRealm(testing.NewUserRealm(payee))
	testing.SetOriginSend(ugnot(1))
	fails(t, cur, "do not send coins", func() { SetCollectorKey(cross(cur), gpubA) }, "collector key with coins")
	testing.SetOriginSend(nil)
}

func TestSubscribe(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Plan", gnot, day)
	setKey(cur, payee, gpubA)
	exp := now() + 30*day
	mid := subscribe(cur, payer, pid, sessA, exp)
	uassert.Equal(t, uint64(1), mid)
	m, ok := MandateOf(payer, sessA)
	uassert.True(t, ok)
	uassert.Equal(t, payer.String(), m.Payer.String())
	uassert.Equal(t, payee.String(), m.Payee.String())
	uassert.Equal(t, sessA.String(), m.Session.String())
	uassert.Equal(t, gpubA, m.SessionPubKey) // the payee's published key
	uassert.Equal(t, exp, m.ExpiresAt)
	uassert.Equal(t, now(), m.NextPullAt) // first payment due at once
	uassert.Equal(t, "active", m.Status)
	uassert.True(t, m.Due)
	uassert.Equal(t, "auth/accounts/"+payer.String()+"/session/"+sessA.String(), m.SessionQuery)
	uassert.True(t, HasMandate(payer, pid))
	uassert.Equal(t, now(), NextPullAt(payer, pid))
	uassert.Equal(t, 1, planOf(pid).Supporters.N)
	uassert.Equal(t, int64(0), bal(realmAddr))

	// A session key that is not the published collector key: no public key recorded.
	subscribe(cur, payer2, pid, sessB, exp)
	m2, _ := MandateOf(payer2, sessB)
	uassert.Equal(t, "", m2.SessionPubKey)

	// Expiry exactly at the maximum term is accepted.
	pid2 := offer(cur, payee2, "Other", gnot, day)
	subscribe(cur, payer, pid2, sessB, now()+MaxTerm)
}

func TestSubscribeRefusals(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Plan", gnot, day)
	pid2 := offer(cur, payee, "Plan 2", gnot, day)
	subscribe(cur, payer, pid, sessA, now()+day)
	cases := []struct {
		who     address
		plan    uint64
		sess    address
		expires int64
		want    string
	}{
		{payer2, 99, sessA, now() + day, "no such plan"},
		{payer2, 0, sessA, now() + day, "no such plan"},
		{payee, pid, sessA, now() + day, "your own plan"},
		{payer2, pid, address(""), now() + day, "invalid session address"},
		{payer2, pid, address("g1notanaddress"), now() + day, "invalid session address"},
		{payer2, pid, payer2, now() + day, "dedicated session key"},
		{payer2, pid, payee, now() + day, "dedicated session key"},
		{payer2, pid, sessA, now(), "in the future"},
		{payer2, pid, sessA, now() - 1, "in the future"},
		{payer2, pid, sessA, 0, "in the future"},
		{payer2, pid, sessA, now() + MaxTerm + 1, "days away"},
		{payer, pid2, sessA, now() + day, "already has an active mandate"}, // same session, other plan
		{payer, pid, sessB, now() + day, "already have an active mandate for this plan"},
	}
	for _, c := range cases {
		testing.SetOriginSend(nil)
		testing.SetRealm(testing.NewUserRealm(c.who))
		fails(t, cur, c.want, func() { Subscribe(cross(cur), c.plan, c.sess, c.expires) }, "Subscribe "+c.want)
	}
	testing.SetRealm(testing.NewUserRealm(payer2))
	testing.SetOriginSend(ugnot(gnot))
	fails(t, cur, "do not send coins", func() { Subscribe(cross(cur), pid, sessA, now()+day) }, "Subscribe with coins")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/someone/proxy"))
	fails(t, cur, "direct calls only", func() { Subscribe(cross(cur), pid, sessA, now()+day) }, "Subscribe from a realm")
}

func TestResubscribeAfterCancelOrExpiry(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Plan", gnot, MinPeriod)
	first := subscribe(cur, payer, pid, sessA, now()+day)
	cancel(cur, payer, payer, sessA)
	uassert.False(t, HasMandate(payer, pid))
	second := subscribe(cur, payer, pid, sessA, now()+120)
	uassert.True(t, second != first)
	uassert.True(t, HasMandate(payer, pid))
	m, _ := MandateOf(payer, sessA)
	uassert.Equal(t, second, m.ID)
	old := MandatesOf(payer, 1)[1] // newest first
	uassert.Equal(t, first, old.ID)
	uassert.Equal(t, "cancelled", old.Status)
	// Let it expire, then subscribe again with the same session.
	testing.SkipHeights(24) // 120 s
	uassert.False(t, HasMandate(payer, pid))
	uassert.Equal(t, int64(0), NextPullAt(payer, pid))
	third := subscribe(cur, payer, pid, sessA, now()+day)
	uassert.True(t, HasMandate(payer, pid))
	uassert.Equal(t, 3, len(MandatesOf(payer, 1)))
	uassert.Equal(t, 1, len(SupportersOf(pid, 1))) // active ones only
	m, _ = MandateOf(payer, sessA)
	uassert.Equal(t, third, m.ID)
}

func TestPullRules(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Plan", 2*gnot, MinPeriod)
	exp := now() + 600
	subscribe(cur, payer, pid, sessA, exp)
	paths := []string{selfPaths}

	// Not a session, or a session with the wrong scope.
	panicsLocal(t, cur, "signed with the mandate's session key", func() { checkPull(false, sessA, paths, payer, ugnot(2*gnot), now()) }, "no session")
	for _, bad := range [][]string{
		nil,
		{},
		{"*"},
		{"vm/exec"},
		{"vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8"},
		{"vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandat"},
		{"vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate/sub"},
		{"vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate", "bank/send"},
		{"vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate", "vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"},
		{"bank/send"},
	} {
		panicsLocal(t, cur, "scoped to exactly", func() { checkPull(true, sessA, bad, payer, ugnot(2*gnot), now()) }, "paths "+strings.Join(bad, ","))
	}
	// No mandate for this payer and session.
	panicsLocal(t, cur, "no active mandate", func() { checkPull(true, sessB, paths, payer, ugnot(2*gnot), now()) }, "other session")
	panicsLocal(t, cur, "no active mandate", func() { checkPull(true, sessA, paths, payer2, ugnot(2*gnot), now()) }, "other payer")
	// Wrong coins.
	for _, c := range []chain.Coins{
		nil,
		ugnot(2*gnot - 1),
		ugnot(2*gnot + 1),
		ugnot(gnot),
		{{Denom: "ufoo", Amount: 2 * gnot}},
		{{Denom: "ufoo", Amount: 1}, {Denom: "ugnot", Amount: 2 * gnot}},
		{{Denom: "ugnot", Amount: 2 * gnot}, {Denom: "uzzz", Amount: 1}},
		{{Denom: "ugnot", Amount: 2 * gnot}, {Denom: "ugnot", Amount: 2 * gnot}},
	} {
		panicsLocal(t, cur, "send exactly 2000000ugnot", func() { checkPull(true, sessA, paths, payer, c, now()) }, "coins "+c.String())
	}

	// First pull: allowed at once.
	t0 := now()
	pullOK(payer, sessA, 2*gnot)
	m, _ := MandateOf(payer, sessA)
	uassert.Equal(t, int64(1), m.Pulls)
	uassert.Equal(t, 2*gnot, m.Paid)
	uassert.Equal(t, t0, m.LastPullAt)
	uassert.Equal(t, t0+MinPeriod, m.NextPullAt)
	uassert.False(t, m.Due)
	p, _ := GetPlan(pid)
	uassert.Equal(t, int64(1), p.Pulls)
	uassert.Equal(t, 2*gnot, p.Paid)
	pe, _ := GetPayee(payee)
	uassert.Equal(t, int64(1), pe.Pulls)
	uassert.Equal(t, 2*gnot, pe.Paid)
	_, _, pulls, paid := Totals()
	uassert.Equal(t, int64(1), pulls)
	uassert.Equal(t, 2*gnot, paid)

	// Too early: right after, and one block before the period ends.
	panicsLocal(t, cur, "too early, next pull from "+itoa(t0+MinPeriod), func() { checkPull(true, sessA, paths, payer, ugnot(2*gnot), now()) }, "second pull at once")
	testing.SkipHeights(11) // +55 s
	panicsLocal(t, cur, "too early", func() { checkPull(true, sessA, paths, payer, ugnot(2*gnot), now()) }, "pull at +55 s")
	uassert.Equal(t, int64(55), now()-t0)
	// The rule at the exact second: allowed at next, refused at next-1.
	panicsLocal(t, cur, "too early", func() { checkPull(true, sessA, paths, payer, ugnot(2*gnot), t0+MinPeriod-1) }, "pull at next-1")
	checkPull(true, sessA, paths, payer, ugnot(2*gnot), t0+MinPeriod)
	testing.SkipHeights(1) // +60 s: due
	m, _ = MandateOf(payer, sessA)
	uassert.True(t, m.Due)
	pullOK(payer, sessA, 2*gnot)
	m, _ = MandateOf(payer, sessA)
	uassert.Equal(t, int64(2), m.Pulls)
	uassert.Equal(t, now()+MinPeriod, m.NextPullAt)

	// A late pull: the next one is one period after it (no catch-up).
	testing.SkipHeights(60) // +300 s, four periods missed
	pullOK(payer, sessA, 2*gnot)
	m, _ = MandateOf(payer, sessA)
	uassert.Equal(t, int64(3), m.Pulls)
	uassert.Equal(t, now()+MinPeriod, m.NextPullAt)
	panicsLocal(t, cur, "too early", func() { checkPull(true, sessA, paths, payer, ugnot(2*gnot), now()) }, "no catch-up")

	// Expiry: exactly at ExpiresAt is refused, one second before is allowed.
	testing.SkipHeights(12)
	checkPull(true, sessA, paths, payer, ugnot(2*gnot), exp-1)
	panicsLocal(t, cur, "expired", func() { checkPull(true, sessA, paths, payer, ugnot(2*gnot), exp) }, "pull at expiry")
	uassert.Equal(t, int64(0), bal(realmAddr))
}

func TestPullCancelled(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Plan", gnot, MinPeriod)
	subscribe(cur, payer, pid, sessA, now()+day)
	subscribe(cur, payer2, pid, sessA, now()+day)
	cancel(cur, payee, payer, sessA) // the payee may cancel too
	panicsLocal(t, cur, "cancelled", func() { checkPull(true, sessA, []string{selfPaths}, payer, ugnot(gnot), now()) }, "pull after cancel")
	// The other payer's mandate on the same key is untouched.
	pullOK(payer2, sessA, gnot)
	uassert.False(t, HasMandate(payer, pid))
	uassert.True(t, HasMandate(payer2, pid))
}

func TestPullEntryPoint(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Plan", gnot, MinPeriod)
	subscribe(cur, payer, pid, sessA, now()+day)
	// Without a session (all that gno test can do) Pull refuses before anything else.
	testing.SetRealm(testing.NewUserRealm(payer))
	testing.SetOriginSend(ugnot(gnot))
	fails(t, cur, "signed with the mandate's session key", func() { Pull(cross(cur)) }, "Pull without session")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/someone/proxy"))
	fails(t, cur, "must be a direct call", func() { Pull(cross(cur)) }, "Pull from a realm")
}

func TestCancel(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Plan", gnot, day)
	subscribe(cur, payer, pid, sessA, now()+day)
	for _, c := range []struct {
		who, p, s address
		want      string
	}{
		{stranger, payer, sessA, "only the payer or the payee"},
		{payee2, payer, sessA, "only the payer or the payee"},
		{sessA, payer, sessA, "only the payer or the payee"},
		{payer, payer, sessB, "no active mandate"},
		{payer, payer2, sessA, "no active mandate"},
	} {
		testing.SetOriginSend(nil)
		testing.SetRealm(testing.NewUserRealm(c.who))
		fails(t, cur, c.want, func() { Cancel(cross(cur), c.p, c.s) }, "Cancel "+c.want)
	}
	testing.SetRealm(testing.NewUserRealm(payer))
	testing.SetOriginSend(ugnot(1))
	fails(t, cur, "do not send coins", func() { Cancel(cross(cur), payer, sessA) }, "Cancel with coins")
	testing.SetOriginSend(nil)

	cancel(cur, payer, payer, sessA)
	m, _ := MandateOf(payer, sessA)
	uassert.Equal(t, "cancelled", m.Status)
	uassert.Equal(t, now(), m.CancelledAt)
	uassert.Equal(t, payer.String(), m.CancelledBy.String())
	uassert.False(t, m.Due)
	testing.SetRealm(testing.NewUserRealm(payer))
	fails(t, cur, "already cancelled", func() { Cancel(cross(cur), payer, sessA) }, "cancel twice")
}

func TestReadsArePlainCopies(cur realm, t *testing.T) {
	resetState()
	pid := offer(cur, payee, "Original", gnot, day)
	subscribe(cur, payer, pid, sessA, now()+day)
	p, _ := GetPlan(pid)
	p.Title = "changed"
	p.Amount = 1
	list := Plans(1)
	list[0].Payee = stranger
	m, _ := MandateOf(payer, sessA)
	m.ExpiresAt = 0
	ms := MandatesOf(payer, 1)
	ms[0].Status = "cancelled"
	p2, _ := GetPlan(pid)
	uassert.Equal(t, "Original", p2.Title)
	uassert.Equal(t, gnot, p2.Amount)
	uassert.Equal(t, payee.String(), Plans(1)[0].Payee.String())
	uassert.True(t, HasMandate(payer, pid))
	_, ok := GetPlan(99)
	uassert.False(t, ok)
	_, ok = MandateOf(stranger, sessA)
	uassert.False(t, ok)
	_, ok = GetPayee(stranger)
	uassert.False(t, ok)
	uassert.False(t, HasMandate(stranger, pid))
	uassert.False(t, HasMandate(payer, 99))
}

func TestPaging(cur realm, t *testing.T) {
	resetState()
	for i := 0; i < 25; i++ {
		offer(cur, payee, "Plan "+itoa(int64(i+1)), gnot, day)
	}
	offer(cur, payee2, "Other creator", gnot, day)
	uassert.Equal(t, PageSize, len(Plans(1)))
	uassert.Equal(t, 6, len(Plans(2)))
	uassert.Equal(t, 0, len(Plans(3)))
	uassert.Equal(t, PageSize, len(Plans(0))) // clamped to page 1
	uassert.Equal(t, PageSize, len(Plans(-5)))
	uassert.Equal(t, 0, len(Plans(1<<30)))
	uassert.Equal(t, "Other creator", Plans(1)[0].Title) // newest first
	uassert.Equal(t, uint64(1), Plans(2)[5].ID)
	uassert.Equal(t, PageSize, len(PlansOf(payee, 1)))
	uassert.Equal(t, 5, len(PlansOf(payee, 2)))
	uassert.Equal(t, uint64(1), PlansOf(payee, 1)[0].ID) // oldest first
	uassert.Equal(t, 1, len(PlansOf(payee2, 1)))
	uassert.Equal(t, 0, len(PlansOf(stranger, 1)))

	// 23 payers on plan 1, all with the same collector key.
	for i := 0; i < 23; i++ {
		who := testutils.TestAddress("md_p" + itoa(int64(i)))
		subscribe(cur, who, 1, sessA, now()+day)
	}
	uassert.Equal(t, PageSize, len(SupportersOf(1, 1)))
	uassert.Equal(t, 3, len(SupportersOf(1, 2)))
	uassert.Equal(t, 0, len(SupportersOf(2, 1)))

	// CollectorScan: plan 1's supporter list, filtered to one key, in
	// windows of ScanLimit entries with a cursor.
	first := testutils.TestAddress("md_p0")
	lines := strings.Split(strings.TrimSuffix(CollectorScan(1, sessA, 0), "\n"), "\n")
	uassert.Equal(t, 24, len(lines))
	uassert.Equal(t, "end", lines[23])
	uassert.Equal(t, "0 1 "+first.String()+" 1000000 "+itoa(now())+" due 0 0", lines[0])
	uassert.Equal(t, "end\n", CollectorScan(1, sessB, 0))
	uassert.Equal(t, "end\n", CollectorScan(99, sessA, 0))
	uassert.Equal(t, "end\n", CollectorScan(1, sessA, 23))
	// after a pull and a cancel: the paid one waits and shows its pulls, the cancelled one is gone
	pullOK(first, sessA, gnot)
	second := testutils.TestAddress("md_p1")
	cancel(cur, second, second, sessA)
	lines = strings.Split(strings.TrimSuffix(CollectorScan(1, sessA, 0), "\n"), "\n")
	uassert.Equal(t, 23, len(lines))
	uassert.Equal(t, "0 1 "+first.String()+" 1000000 "+itoa(now()+day)+" wait 1 1", lines[0])
	uassert.True(t, strings.HasPrefix(lines[1], "2 3 "))
	// CollectorPlans
	pl := strings.Split(strings.TrimSuffix(CollectorPlans(payee, 1), "\n"), "\n")
	uassert.Equal(t, PageSize+1, len(pl))
	uassert.Equal(t, "1 1000000 86400 23", pl[0])
	uassert.Equal(t, "more", pl[PageSize])
	uassert.Equal(t, "end\n", CollectorPlans(stranger, 1))
	_, nMandates, _, _ := Totals()
	uassert.Equal(t, 23, nMandates)
}

func TestFormat(t *testing.T) {
	uassert.Equal(t, "1 GNOT", formatUgnot(1_000_000))
	uassert.Equal(t, "0.1 GNOT", formatUgnot(100_000))
	uassert.Equal(t, "0.05 GNOT", formatUgnot(50_000))
	uassert.Equal(t, "1.000001 GNOT", formatUgnot(1_000_001))
	uassert.Equal(t, "0 GNOT", formatUgnot(0))
	uassert.Equal(t, "1000000 GNOT", formatUgnot(MaxAmount))
	uassert.Equal(t, "minute", formatPeriod(60))
	uassert.Equal(t, "90 seconds", formatPeriod(90))
	uassert.Equal(t, "2 hours", formatPeriod(7200))
	uassert.Equal(t, "day", formatPeriod(86400))
	uassert.Equal(t, "week", formatPeriod(604800))
	uassert.Equal(t, "30 days", formatPeriod(30*86400))
	uassert.Equal(t, "30 days", formatPeriod(MaxPeriod))
	uassert.Equal(t, "0000000001", pad(1))
	uassert.Equal(t, "18446744073709551615", pad(18446744073709551615))
	uassert.True(t, pad(9) < pad(10))
	uassert.Equal(t, 1, pageParam(""))
	uassert.Equal(t, 3, pageParam("page=3"))
	uassert.Equal(t, 3, pageParam("x=1&page=3"))
	uassert.Equal(t, 1, pageParam("page=0"))
	uassert.Equal(t, 1, pageParam("page=-2"))
	uassert.Equal(t, 1, pageParam("page=abc"))
	uassert.Equal(t, 1, pageParam("page=99999999999"))
	uassert.Equal(t, "1970-01-01 00:00 UTC", formatTime(0))
	uassert.Equal(t, "never", formatTimeOrNever(0))
}
