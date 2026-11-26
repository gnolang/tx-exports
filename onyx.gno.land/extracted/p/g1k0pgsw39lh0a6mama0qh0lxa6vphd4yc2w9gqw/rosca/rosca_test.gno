package rosca

import (
	"testing"
)

var (
	ayse     = address("g130fx98fj7kc5em506jm7zfrzatup7hwddgvs6m")
	mehmet   = address("g1yy65pcawm6z5n75efheqntx9qn3qptfnhjguq2")
	zeynep   = address("g1q542pn3a7q32ayedxndx88lff832zl524jhjry")
	stranger = address("g1k0pgsw39lh0a6mama0qh0lxa6vphd4yc2w9gqw")
)

const (
	t0     = int64(1_800_000_000)
	day    = int64(86400)
	amount = int64(1_000_000) // 1 GNOT
)

// ledger tracks coins in and out so every test can check that the circle's
// books match what a realm would actually be holding.
type ledger struct {
	t   *testing.T
	c   *Circle
	in  int64
	out int64
}

func (l *ledger) check(step string) {
	l.t.Helper()
	if got, want := l.c.Held(), l.in-l.out; got != want {
		l.t.Fatalf("%s: Held() = %d, coins in-out = %d", step, got, want)
	}
}

func (l *ledger) join(who address, now int64) {
	l.t.Helper()
	sent := l.c.CollateralDue()
	if err := l.c.Join(who, sent, now); err != nil {
		l.t.Fatalf("join %s: %v", who, err)
	}
	l.in += sent
	l.check("join")
}

func (l *ledger) pay(who address, now int64) {
	l.t.Helper()
	if err := l.c.Pay(who, l.c.Contribution(), now); err != nil {
		l.t.Fatalf("pay %s: %v", who, err)
	}
	l.in += l.c.Contribution()
	l.check("pay")
}

func (l *ledger) withdraw(who address) int64 {
	l.t.Helper()
	amt, err := l.c.Withdraw(who)
	if err != nil {
		l.t.Fatalf("withdraw %s: %v", who, err)
	}
	l.out += amt
	l.check("withdraw")
	return amt
}

func newCircle(t *testing.T, collateral int) *ledger {
	t.Helper()
	c, err := New(Config{
		Name:             "Salı günü",
		Contribution:     amount,
		Period:           7 * day,
		CollateralRounds: collateral,
		JoinWindow:       3 * day,
		Members:          []address{ayse, mehmet, zeynep},
	}, ayse, t0)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return &ledger{t: t, c: c}
}

func startedCircle(t *testing.T, collateral int) *ledger {
	l := newCircle(t, collateral)
	l.join(ayse, t0+1)
	l.join(mehmet, t0+2)
	l.join(zeynep, t0+3)
	if l.c.Status() != Active || l.c.StartedAt() != t0+3 {
		t.Fatalf("circle should be active since t0+3, got %s at %d", l.c.Status(), l.c.StartedAt())
	}
	return l
}

func expectErr(t *testing.T, got, want error) {
	t.Helper()
	if got != want {
		t.Fatalf("got error %v, want %v", got, want)
	}
}

func TestNewValidation(t *testing.T) {
	base := Config{
		Name: "x", Contribution: amount, Period: day, JoinWindow: day,
		Members: []address{ayse, mehmet},
	}
	cases := []struct {
		name string
		mod  func(c *Config)
		org  address
		want error
	}{
		{"empty name", func(c *Config) { c.Name = "   " }, ayse, ErrBadName},
		{"long name", func(c *Config) { c.Name = "0123456789012345678901234567890123456789012345678" }, ayse, ErrBadName},
		{"zero contribution", func(c *Config) { c.Contribution = 0 }, ayse, ErrBadContribution},
		{"huge contribution", func(c *Config) { c.Contribution = MaxContribution + 1 }, ayse, ErrBadContribution},
		{"short period", func(c *Config) { c.Period = 59 }, ayse, ErrBadPeriod},
		{"long period", func(c *Config) { c.Period = MaxPeriod + 1 }, ayse, ErrBadPeriod},
		{"short join window", func(c *Config) { c.JoinWindow = 10 }, ayse, ErrBadJoinWindow},
		{"one member", func(c *Config) { c.Members = []address{ayse} }, ayse, ErrBadMemberCount},
		{"13 members", func(c *Config) { c.Members = make([]address, 13) }, ayse, ErrBadMemberCount},
		{"bad address", func(c *Config) { c.Members = []address{ayse, "nope"} }, ayse, ErrBadMember},
		{"duplicate", func(c *Config) { c.Members = []address{ayse, ayse} }, ayse, ErrDuplicateMember},
		{"collateral too high", func(c *Config) { c.CollateralRounds = 2 }, ayse, ErrBadCollateral},
		{"negative collateral", func(c *Config) { c.CollateralRounds = -1 }, ayse, ErrBadCollateral},
		{"organizer outside", func(c *Config) {}, zeynep, ErrOrganizerNotIn},
	}
	for _, tc := range cases {
		cfg := base
		cfg.Members = append([]address{}, base.Members...)
		tc.mod(&cfg)
		_, err := New(cfg, tc.org, t0)
		if err != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, err, tc.want)
		}
	}
	c, err := New(base, ayse, t0)
	if err != nil || c.Status() != Forming || c.JoinBy() != t0+day {
		t.Fatalf("valid config rejected: %v", err)
	}
}

func TestConfigIsCopied(t *testing.T) {
	members := []address{ayse, mehmet}
	c, _ := New(Config{Name: "x", Contribution: 1, Period: 60, JoinWindow: 60, Members: members}, ayse, t0)
	members[0] = zeynep
	if c.Recipient(0) != ayse {
		t.Fatal("circle must not alias the caller's member slice")
	}
}

func TestHappyPathFullCircle(t *testing.T) {
	l := startedCircle(t, 2) // fully secured: 2 = members-1
	if !l.c.FullySecured() {
		t.Fatal("2 collateral rounds with 3 members must be fully secured")
	}
	recipients := []address{ayse, mehmet, zeynep}
	for r := 0; r < 3; r++ {
		due := l.c.DueAt()
		if due != t0+3+int64(r+1)*7*day {
			t.Fatalf("round %d due %d", r, due)
		}
		l.pay(zeynep, due-10)
		l.pay(ayse, due-5)
		if l.c.Round() != r {
			t.Fatalf("round closed early")
		}
		l.pay(mehmet, due)
		h := l.c.History()
		if len(h) != r+1 || h[r].Recipient != recipients[r] || h[r].Pot != 3*amount || h[r].Marks != "PPP" {
			t.Fatalf("round %d record: %+v", r, h[r])
		}
	}
	if l.c.Status() != Completed {
		t.Fatalf("status %s", l.c.Status())
	}
	for _, a := range recipients {
		m, _ := l.c.MemberOf(a)
		// pot (3) + collateral back (2), having paid 3 + 2.
		if m.Claimable != 5*amount || m.PaidIn != 3*amount || m.Received != 3*amount {
			t.Fatalf("%s books: %+v", a, m)
		}
		if got := l.withdraw(a); got != 5*amount {
			t.Fatalf("withdraw %d", got)
		}
	}
	if l.c.Held() != 0 {
		t.Fatalf("held after everyone withdrew: %d", l.c.Held())
	}
	expectErr(t, l.c.Pay(ayse, amount, t0), ErrWrongStatus)
	_, err := l.c.Withdraw(ayse)
	expectErr(t, err, ErrNothingToClaim)
}

func TestJoinRules(t *testing.T) {
	l := newCircle(t, 1)
	expectErr(t, l.c.Join(stranger, amount, t0), ErrNotMember)
	expectErr(t, l.c.Join(ayse, amount-1, t0), ErrWrongAmount)
	expectErr(t, l.c.Pay(ayse, amount, t0), ErrWrongStatus)
	l.join(ayse, t0)
	expectErr(t, l.c.Join(ayse, amount, t0), ErrAlreadyJoined)
	expectErr(t, l.c.Join(mehmet, amount, t0+3*day+1), ErrJoinClosed)
	// Zero-collateral circles join with nothing attached.
	z := newCircle(t, 0)
	expectErr(t, z.c.Join(ayse, 1, t0), ErrWrongAmount)
	z.join(ayse, t0)
}

func TestPayRules(t *testing.T) {
	l := startedCircle(t, 1)
	expectErr(t, l.c.Pay(stranger, amount, t0+10), ErrNotMember)
	expectErr(t, l.c.Pay(ayse, 2*amount, t0+10), ErrWrongAmount)
	l.pay(ayse, t0+10)
	expectErr(t, l.c.Pay(ayse, amount, t0+11), ErrAlreadyPaid)
	expectErr(t, l.c.Settle(l.c.DueAt()), ErrNotDue)
}

func TestLatePaymentStillCounts(t *testing.T) {
	l := startedCircle(t, 0)
	due := l.c.DueAt()
	l.pay(ayse, due)
	l.pay(mehmet, due)
	l.pay(zeynep, due+1) // late, but nobody settled
	h := l.c.History()
	if h[0].Marks != "PPL" {
		t.Fatalf("marks %q", h[0].Marks)
	}
	m, _ := l.c.MemberOf(zeynep)
	if m.Late != 1 {
		t.Fatalf("late count %d", m.Late)
	}
}

func TestSettleCoversFromCollateral(t *testing.T) {
	l := startedCircle(t, 1)
	due := l.c.DueAt()
	l.pay(ayse, due-1)
	l.pay(mehmet, due-1)
	if err := l.c.Settle(due + 1); err != nil {
		t.Fatal(err)
	}
	l.check("settle")
	h := l.c.History()
	if h[0].Marks != "PPC" || h[0].Pot != 3*amount || h[0].Recipient != ayse {
		t.Fatalf("round: %+v", h[0])
	}
	z, _ := l.c.MemberOf(zeynep)
	if z.Collateral != 0 || z.Covered != 1 || z.PaidIn != amount {
		t.Fatalf("zeynep: %+v", z)
	}
	// Next round is due one period after the first due time, not after Settle.
	if l.c.DueAt() != due+7*day {
		t.Fatalf("schedule drifted: %d", l.c.DueAt())
	}
}

func TestDefaultBreaksAndSharesForfeit(t *testing.T) {
	// 3 members, 1 round of collateral. Ayşe receives round 1, then stops paying.
	l := startedCircle(t, 1)
	due := l.c.DueAt()
	l.pay(ayse, due)
	l.pay(mehmet, due)
	l.pay(zeynep, due)
	l.withdraw(ayse) // she takes the 3 GNOT pot

	// Round 2: Ayşe misses; her collateral covers it.
	due = l.c.DueAt()
	l.pay(mehmet, due)
	l.pay(zeynep, due)
	if err := l.c.Settle(due + 1); err != nil {
		t.Fatal(err)
	}
	l.check("covered")
	if l.c.Status() != Active || l.c.Recipient(1) != mehmet {
		t.Fatal("round 2 should have closed for Mehmet")
	}
	// Round 3: Ayşe misses again, nothing left: the circle breaks.
	due = l.c.DueAt()
	l.pay(mehmet, due)
	if err := l.c.Settle(due + 1); err != nil {
		t.Fatal(err)
	}
	l.check("broken")
	if l.c.Status() != Broken {
		t.Fatalf("status %s", l.c.Status())
	}
	h := l.c.History()
	// Zeynep did not pay round 3 either, but her collateral covered her; the
	// cover is undone when the circle breaks.
	if h[2].Marks != "XPC" || h[2].Pot != 0 {
		t.Fatalf("breaking round: %+v", h[2])
	}
	a, _ := l.c.MemberOf(ayse)
	m, _ := l.c.MemberOf(mehmet)
	z, _ := l.c.MemberOf(zeynep)
	if !a.Defaulted || a.Claimable != 0 {
		t.Fatalf("ayse: %+v", a)
	}
	// Mehmet: received round 2 pot (3) + his round-3 payment back (1) + collateral (1).
	if m.Claimable != 5*amount {
		t.Fatalf("mehmet: %+v", m)
	}
	// Zeynep paid 2, received 0, gets her collateral (1) back: she is 2 GNOT short.
	if z.Claimable != amount || z.PaidIn-z.Received != 2*amount {
		t.Fatalf("zeynep: %+v", z)
	}
	l.withdraw(mehmet)
	l.withdraw(zeynep)
	if l.c.Held() != 0 {
		t.Fatalf("held %d", l.c.Held())
	}
}

func TestForfeitGoesToShortMembers(t *testing.T) {
	// 4 members, 2 rounds of collateral. Ayşe (round 1) gets the pot, then
	// misses three times: two covered, the third breaks the circle with 0
	// left. Use a 4th member with partial collateral to leave a leftover.
	c, err := New(Config{
		Name: "dörtlü", Contribution: 3, Period: 60, JoinWindow: 60, CollateralRounds: 2,
		Members: []address{ayse, mehmet, zeynep, stranger},
	}, ayse, t0)
	if err != nil {
		t.Fatal(err)
	}
	l := &ledger{t: t, c: c}
	for _, a := range []address{ayse, mehmet, zeynep, stranger} {
		l.join(a, t0)
	}
	// Round 1: all pay, Ayşe receives 12.
	for _, a := range []address{ayse, mehmet, zeynep, stranger} {
		l.pay(a, t0+1)
	}
	// Round 2: Ayşe and Mehmet miss: both covered (collateral 6 -> 3).
	l.pay(zeynep, t0+61)
	l.pay(stranger, t0+61)
	if err := c.Settle(t0 + 121); err != nil {
		t.Fatal(err)
	}
	// Round 3: Ayşe misses (covered, 3 -> 0); Mehmet misses (covered, 3 -> 0).
	l.pay(zeynep, t0+130)
	l.pay(stranger, t0+130)
	if err := c.Settle(t0 + 181); err != nil {
		t.Fatal(err)
	}
	// Round 4 (Stranger's turn): Ayşe misses with 0 left -> break.
	l.pay(mehmet, t0+190)
	l.pay(zeynep, t0+190)
	l.pay(stranger, t0+190)
	if err := c.Settle(t0 + 241); err != nil {
		t.Fatal(err)
	}
	l.check("broken")
	if c.Status() != Broken {
		t.Fatalf("status %s", c.Status())
	}
	s, _ := c.MemberOf(stranger)
	// Stranger paid 9 in rounds 1-3 and received nothing: 9 short. Ayşe never
	// withdrew her 12 pot, so it repays those 9 in full; Stranger also gets
	// the round-4 payment (3) and collateral (6) back.
	if s.Compensated != 9 || s.Claimable != 18 {
		t.Fatalf("stranger: %+v", s)
	}
	a, _ := c.MemberOf(ayse)
	if a.Claimable != 3 { // 12 - 9 back to her
		t.Fatalf("ayse: %+v", a)
	}
	for _, a := range []address{ayse, mehmet, zeynep, stranger} {
		if m, _ := c.MemberOf(a); m.Claimable > 0 {
			l.withdraw(a)
		}
	}
	if c.Held() != 0 {
		t.Fatalf("held %d", c.Held())
	}
}

func TestMulDiv(t *testing.T) {
	if got := mulDiv(7, 2, 3); got != 4 {
		t.Fatalf("mulDiv(7,2,3) = %d", got)
	}
	big := int64(12) * MaxContribution
	if got := mulDiv(big, big, big); got != big {
		t.Fatalf("mulDiv overflow: %d", got)
	}
}

func TestUnwithdrawnPotRepaysVictims(t *testing.T) {
	// Like TestDefaultBreaksAndSharesForfeit, but Ayşe never withdraws her
	// round-1 pot before defaulting: it repays Zeynep's shortfall in full and
	// the rest goes back to Ayşe.
	l := startedCircle(t, 1)
	due := l.c.DueAt()
	l.pay(ayse, due)
	l.pay(mehmet, due)
	l.pay(zeynep, due)
	due = l.c.DueAt()
	l.pay(mehmet, due)
	l.pay(zeynep, due)
	l.c.Settle(due + 1) // Ayşe covered
	due = l.c.DueAt()
	l.pay(mehmet, due)
	l.pay(zeynep, due)
	l.c.Settle(due + 1) // Ayşe broke
	l.check("broken")
	a, _ := l.c.MemberOf(ayse)
	z, _ := l.c.MemberOf(zeynep)
	m, _ := l.c.MemberOf(mehmet)
	// Zeynep paid 2 (rounds 1-2), got 0: repaid 2, plus round-3 payment and collateral back.
	if z.Compensated != 2*amount || z.Claimable != 4*amount {
		t.Fatalf("zeynep %+v", z)
	}
	// Mehmet paid 2, received 3: not short. Round-3 payment + collateral back.
	if m.Compensated != 0 || m.Claimable != 5*amount {
		t.Fatalf("mehmet %+v", m)
	}
	// Ayşe's 3 GNOT pot minus Zeynep's 2.
	if a.Claimable != amount {
		t.Fatalf("ayse %+v", a)
	}
	l.withdraw(ayse)
	l.withdraw(mehmet)
	l.withdraw(zeynep)
	if l.c.Held() != 0 {
		t.Fatalf("held %d", l.c.Held())
	}
}

func TestDefaultWithNothingToPool(t *testing.T) {
	// No collateral. Mehmet receives round 1 and withdraws it; Stranger misses
	// round 2 before anyone else was paid, so the pool is empty and Ayşe, who
	// is short, can only get her round-2 payment back.
	c, _ := New(Config{Name: "dörtlü", Contribution: 3, Period: 60, JoinWindow: 60,
		Members: []address{mehmet, ayse, zeynep, stranger}}, ayse, t0)
	l := &ledger{t: t, c: c}
	for _, a := range []address{ayse, mehmet, zeynep, stranger} {
		l.join(a, t0)
	}
	for _, a := range []address{ayse, mehmet, zeynep, stranger} {
		l.pay(a, t0+1)
	}
	l.withdraw(mehmet) // 12
	for _, a := range []address{ayse, mehmet, zeynep} {
		l.pay(a, t0+61) // Stranger misses round 2 with no collateral
	}
	if err := c.Settle(t0 + 121); err != nil {
		t.Fatal(err)
	}
	l.check("broken")
	s, _ := c.MemberOf(stranger)
	a, _ := c.MemberOf(ayse)
	if !s.Defaulted || s.Claimable != 0 {
		t.Fatalf("stranger %+v", s)
	}
	if a.Claimable != 3 || a.Compensated != 0 {
		t.Fatalf("ayse %+v", a)
	}
}

func TestPartialPoolSplitsByShortfall(t *testing.T) {
	// Direct check of the proportional branch: 3 honest members short 1, 2
	// and 3; pool of 4 -> shares floor(4*1/6)=0, floor(4*2/6)=1,
	// floor(4*3/6)=2, dust 1 to the first short member.
	c, _ := New(Config{Name: "x", Contribution: 1, Period: 60, JoinWindow: 60,
		Members: []address{ayse, mehmet, zeynep, stranger}}, ayse, t0)
	c.status = Active
	c.members[0].PaidIn = 1
	c.members[1].PaidIn = 2
	c.members[2].PaidIn = 3
	c.members[3].Defaulted = true
	c.members[3].Claimable = 4
	c.marks[3] = Missed // the others' marks stay Unpaid: nothing to undo this round
	c.breakCircle(t0)
	got := []int64{c.members[0].Compensated, c.members[1].Compensated, c.members[2].Compensated}
	if got[0] != 1 || got[1] != 1 || got[2] != 2 || c.members[3].Claimable != 0 {
		t.Fatalf("shares %v, defaulter left %d", got, c.members[3].Claimable)
	}
}

func TestNoShortfallReturnsLeftoverToDefaulter(t *testing.T) {
	// 2 members, collateral 1. Round 1: both pay, Ayşe receives 2.
	// Round 2: Mehmet's turn; Ayşe misses -> covered from collateral, closes,
	// circle completes. No break possible with full security; so instead
	// make Mehmet the defaulter in round 1 before anyone received:
	// covered, then round 2 he misses again with 0 -> break. Ayşe received 2,
	// paid 2: not short. Mehmet's leftover is 0. Nobody short: forfeit 0.
	c, _ := New(Config{Name: "ikili", Contribution: 5, Period: 60, JoinWindow: 60, CollateralRounds: 1,
		Members: []address{ayse, mehmet}}, ayse, t0)
	l := &ledger{t: t, c: c}
	l.join(ayse, t0)
	l.join(mehmet, t0)
	l.pay(ayse, t0+1)
	if err := c.Settle(t0 + 61); err != nil {
		t.Fatal(err)
	}
	l.pay(ayse, t0+70)
	if err := c.Settle(t0 + 121); err != nil {
		t.Fatal(err)
	}
	l.check("broken")
	if c.Status() != Broken {
		t.Fatalf("status %s", c.Status())
	}
	a, _ := c.MemberOf(ayse)
	// Ayşe: received 10, round-2 payment (5) back, collateral (5) back.
	if a.Claimable != 20 {
		t.Fatalf("ayse %+v", a)
	}
	l.withdraw(ayse)
	if c.Held() != 0 {
		t.Fatalf("held %d", c.Held())
	}
}

func TestSwap(t *testing.T) {
	l := newCircle(t, 0)
	expectErr(t, l.c.ProposeSwap(ayse, ayse), ErrSelfSwap)
	expectErr(t, l.c.ProposeSwap(ayse, stranger), ErrNotMember)
	expectErr(t, l.c.AcceptSwap(zeynep, ayse), ErrNoProposal)
	if err := l.c.ProposeSwap(ayse, zeynep); err != nil {
		t.Fatal(err)
	}
	expectErr(t, l.c.AcceptSwap(mehmet, ayse), ErrNoProposal)
	if err := l.c.AcceptSwap(zeynep, ayse); err != nil {
		t.Fatal(err)
	}
	if l.c.Recipient(0) != zeynep || l.c.Recipient(2) != ayse || l.c.TurnOf(ayse) != 2 {
		t.Fatal("turns not swapped")
	}
	l.join(ayse, t0)
	l.join(mehmet, t0)
	l.join(zeynep, t0)
	// Active: round 0 (Zeynep's) can no longer move.
	expectErr(t, l.c.ProposeSwap(mehmet, zeynep), ErrBadSwap)
	if err := l.c.ProposeSwap(mehmet, ayse); err != nil {
		t.Fatal(err)
	}
	// Round 0 closes; Mehmet's turn (round 1) is now current, so the
	// proposal is dropped as stale.
	due := l.c.DueAt()
	l.pay(ayse, due)
	l.pay(mehmet, due)
	l.pay(zeynep, due)
	expectErr(t, l.c.AcceptSwap(ayse, mehmet), ErrNoProposal)
}

func TestCancel(t *testing.T) {
	l := newCircle(t, 1)
	l.join(mehmet, t0)
	expectErr(t, l.c.Cancel(mehmet, t0+day), ErrCannotCancel)
	if err := l.c.Cancel(mehmet, t0+3*day+1); err != nil {
		t.Fatal(err)
	}
	l.check("cancel")
	if l.c.Status() != Cancelled || l.c.Note() != "not every member joined in time" {
		t.Fatalf("%s %q", l.c.Status(), l.c.Note())
	}
	if got := l.withdraw(mehmet); got != amount {
		t.Fatalf("refund %d", got)
	}
	o := newCircle(t, 1)
	if err := o.c.Cancel(ayse, t0+1); err != nil || o.c.Note() != "cancelled by the organizer" {
		t.Fatalf("organizer cancel: %v", err)
	}
	s := startedCircle(t, 1)
	expectErr(t, s.c.Cancel(ayse, t0+10), ErrWrongStatus)
}
