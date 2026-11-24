package gauntlet

import (
	"strings"
	"testing"
	"time"
)

var (
	alice  = address("g1alice000000000000000000000000000000000")
	bob    = address("g1bob00000000000000000000000000000000000")
	carol  = address("g1carol00000000000000000000000000000000")
	poster = address("g1poster0000000000000000000000000000000")
	t0     = time.Date(2026, 12, 1, 12, 0, 0, 0, time.UTC)
)

func reverse(s string) string {
	r := []rune(s)
	for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
		r[i], r[j] = r[j], r[i]
	}
	return string(r)
}

func wrong(s string) string { return s }

func hardcoded(s string) string {
	if s == "abc" {
		return "cba"
	}
	return s
}

func newBoard(t *testing.T) (*Board, *Challenge) {
	b := &Board{}
	cases, err := ParseCases("abc => cba\nhello => olleh\n# comment\n\na\\nb => b\\na")
	if err != nil {
		t.Fatal(err)
	}
	c, err := b.Post(PostParams{
		Title: "Reverse", Poster: poster, Reward: 1000, Bond: 10,
		Deadline: t0.Add(24 * time.Hour), Window: time.Hour, Cases: cases,
	}, t0)
	if err != nil {
		t.Fatal(err)
	}
	return b, c
}

func TestParseCases(t *testing.T) {
	cs, err := ParseCases("a\\tb => x\\\\y")
	if err != nil {
		t.Fatal(err)
	}
	if cs[0].In != "a\tb" || cs[0].Want != `x\y` {
		t.Fatalf("got %q %q", cs[0].In, cs[0].Want)
	}
	if _, err := ParseCases("no arrow"); err != ErrBadCaseLine {
		t.Fatalf("want ErrBadCaseLine, got %v", err)
	}
	if _, err := ParseCases("  \n# x"); err != ErrNoCases {
		t.Fatalf("want ErrNoCases, got %v", err)
	}
	if Unescape(Escape("a\n\tb\\")) != "a\n\tb\\" {
		t.Fatal("escape roundtrip")
	}
}

func TestPostValidation(t *testing.T) {
	b := &Board{}
	base := PostParams{Title: "x", Poster: poster, Reward: 1, Deadline: t0.Add(time.Hour), Window: time.Hour, Cases: []Case{{"a", "b"}}}
	bad := []struct {
		mut  func(p *PostParams)
		want error
	}{
		{func(p *PostParams) { p.Title = "" }, ErrBadTitle},
		{func(p *PostParams) { p.Reward = 0 }, ErrBadReward},
		{func(p *PostParams) { p.Bond = -1 }, ErrBadBond},
		{func(p *PostParams) { p.Deadline = t0 }, ErrBadDeadline},
		{func(p *PostParams) { p.Window = time.Second }, ErrBadWindow},
		{func(p *PostParams) { p.Cases = nil }, ErrNoTests},
	}
	for i, tc := range bad {
		p := base
		tc.mut(&p)
		if _, err := b.Post(p, t0); err != tc.want {
			t.Fatalf("case %d: want %v, got %v", i, tc.want, err)
		}
	}
	if b.Size() != 0 {
		t.Fatal("nothing should be posted")
	}
}

func TestHappyPath(t *testing.T) {
	b, c := newBoard(t)
	path := "gno.land/r/g1alice/rev"
	if _, err := b.Commit(c.ID, alice, HashSolution(path, "s1"), 10, t0.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	a, pay, err := b.Reveal(c.ID, path, "s1", reverse, t0.Add(2*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if a.State != Passed || a.Report.Passed != 3 {
		t.Fatalf("state %v report %+v", a.State, a.Report)
	}
	if c.Status != Won || c.Winner != a {
		t.Fatal("alice should have won")
	}
	if len(pay) != 2 || pay[0].Amount != 10 || pay[1].To != alice || pay[1].Amount != 1000 {
		t.Fatalf("payouts %+v", pay)
	}
}

func TestFailingSolutionKeepsChallengeOpen(t *testing.T) {
	b, c := newBoard(t)
	path := "gno.land/r/g1bob/rev"
	b.Commit(c.ID, bob, HashSolution(path, "x"), 10, t0)
	a, pay, err := b.Reveal(c.ID, path, "x", hardcoded, t0.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if a.State != Failed || a.Report.Passed != 1 || a.Report.FailIn != "hello" {
		t.Fatalf("report %+v", a.Report)
	}
	if c.Status != Open || len(pay) != 1 {
		t.Fatalf("status %v payouts %+v", c.Status, pay)
	}
	// Bob can commit again after a failure.
	if _, err := b.Commit(c.ID, bob, HashSolution(path+"2", "y"), 10, t0.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
}

// The core fairness property: a copier who commits later never wins, even
// if they reveal first.
func TestEarlierCommitWinsOverFasterCopier(t *testing.T) {
	b, c := newBoard(t)
	honest := "gno.land/r/g1alice/rev"
	copier := "gno.land/r/g1carol/rev"
	b.Commit(c.ID, alice, HashSolution(honest, "a"), 10, t0)
	b.Commit(c.ID, carol, HashSolution(copier, "c"), 10, t0.Add(time.Minute))

	// Carol reveals first and passes, but Alice is earlier in line.
	_, pay, err := b.Reveal(c.ID, copier, "c", reverse, t0.Add(2*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if c.Status != Open || len(pay) != 1 {
		t.Fatalf("must wait for alice: status %v payouts %+v", c.Status, pay)
	}
	_, pay, _ = b.Reveal(c.ID, honest, "a", reverse, t0.Add(3*time.Minute))
	if c.Status != Won || c.Winner.Solver != alice {
		t.Fatal("alice should win")
	}
	if pay[1].To != alice || pay[1].Amount != 1000 {
		t.Fatalf("payouts %+v", pay)
	}
}

func TestExpiredCommitForfeitsBondAndUnblocks(t *testing.T) {
	b, c := newBoard(t)
	slow := "gno.land/r/g1bob/rev"
	fast := "gno.land/r/g1alice/rev"
	b.Commit(c.ID, bob, HashSolution(slow, "b"), 10, t0)
	b.Commit(c.ID, alice, HashSolution(fast, "a"), 10, t0.Add(time.Minute))
	b.Reveal(c.ID, fast, "a", reverse, t0.Add(2*time.Minute))
	if c.Status != Open {
		t.Fatal("bob's commit is still in its window")
	}
	// After bob's window, anyone can settle.
	pay, _ := b.Settle(c.ID, t0.Add(61*time.Minute))
	if c.Status != Won || c.Winner.Solver != alice {
		t.Fatal("alice should win after bob expires")
	}
	if c.Attempts[0].State != Expired || c.Forfeited != 10 || pay[0].Amount != 1010 {
		t.Fatalf("forfeit not applied: %+v", pay)
	}
	// Bob is too late to reveal now.
	if _, _, err := b.Reveal(c.ID, slow, "b", reverse, t0.Add(62*time.Minute)); err != ErrNoCommit {
		t.Fatalf("want ErrNoCommit, got %v", err)
	}
}

func TestLaterPendingCommitsAreRefundedWhenWon(t *testing.T) {
	b, c := newBoard(t)
	b.Commit(c.ID, alice, HashSolution("gno.land/r/a/x", "1"), 10, t0)
	b.Commit(c.ID, bob, HashSolution("gno.land/r/b/x", "2"), 10, t0)
	_, pay, _ := b.Reveal(c.ID, "gno.land/r/a/x", "1", reverse, t0)
	if c.Attempts[1].State != Refunded {
		t.Fatal("bob should be refunded")
	}
	last := pay[len(pay)-1]
	if last.To != bob || last.Amount != 10 {
		t.Fatalf("payouts %+v", pay)
	}
}

func TestNoWinnerReturnsRewardToPoster(t *testing.T) {
	b, c := newBoard(t)
	b.Commit(c.ID, bob, HashSolution("gno.land/r/b/x", "1"), 10, t0)
	b.Reveal(c.ID, "gno.land/r/b/x", "1", wrong, t0.Add(time.Minute))
	if pay, _ := b.Settle(c.ID, t0.Add(time.Hour)); pay != nil {
		t.Fatal("too early to close")
	}
	pay, _ := b.Settle(c.ID, t0.Add(25*time.Hour))
	if c.Status != Closed || len(pay) != 1 || pay[0].To != poster || pay[0].Amount != 1000 {
		t.Fatalf("status %v payouts %+v", c.Status, pay)
	}
	if _, err := b.Commit(c.ID, alice, HashSolution("gno.land/r/a/x", "1"), 10, t0.Add(26*time.Hour)); err != ErrNotOpen {
		t.Fatalf("want ErrNotOpen, got %v", err)
	}
}

func TestCommitRules(t *testing.T) {
	b, c := newBoard(t)
	h := HashSolution("gno.land/r/a/x", "1")
	if _, err := b.Commit(c.ID, alice, h, 9, t0); err != ErrWrongBond {
		t.Fatalf("want ErrWrongBond, got %v", err)
	}
	if _, err := b.Commit(c.ID, alice, "zz", 10, t0); err != ErrBadHash {
		t.Fatalf("want ErrBadHash, got %v", err)
	}
	if _, err := b.Commit(c.ID, alice, strings.ToUpper(h), 10, t0); err != ErrBadHash {
		t.Fatalf("uppercase hash should be rejected, got %v", err)
	}
	b.Commit(c.ID, alice, h, 10, t0)
	if _, err := b.Commit(c.ID, bob, h, 10, t0); err != ErrDuplicateHash {
		t.Fatalf("want ErrDuplicateHash, got %v", err)
	}
	if _, err := b.Commit(c.ID, alice, HashSolution("gno.land/r/a/y", "1"), 10, t0); err != ErrHasPending {
		t.Fatalf("want ErrHasPending, got %v", err)
	}
	if _, err := b.Commit(c.ID, bob, HashSolution("gno.land/r/b/x", "1"), 10, t0.Add(24*time.Hour)); err != ErrPastDeadline {
		t.Fatalf("want ErrPastDeadline, got %v", err)
	}
	if _, err := b.Commit(99, bob, h, 10, t0); err != ErrNotFound {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestRevealRules(t *testing.T) {
	b, c := newBoard(t)
	b.Commit(c.ID, alice, HashSolution("gno.land/r/a/x", "1"), 10, t0)
	if _, _, err := b.Reveal(c.ID, "gno.land/e/a/run", "1", reverse, t0); err != ErrNotRealm {
		t.Fatalf("want ErrNotRealm, got %v", err)
	}
	if _, _, err := b.Reveal(c.ID, "gno.land/r/a/x", "wrong-salt", reverse, t0); err != ErrNoCommit {
		t.Fatalf("want ErrNoCommit, got %v", err)
	}
	// Someone else's realm cannot claim Alice's commit.
	if _, _, err := b.Reveal(c.ID, "gno.land/r/c/x", "1", reverse, t0); err != ErrNoCommit {
		t.Fatalf("want ErrNoCommit, got %v", err)
	}
	if _, _, err := b.Reveal(c.ID, "gno.land/r/a/x", "1", reverse, t0.Add(2*time.Hour)); err != ErrRevealTooLate {
		t.Fatalf("want ErrRevealTooLate, got %v", err)
	}
}

func TestJudgeDefeatsLookupTables(t *testing.T) {
	b := &Board{}
	judge := &Judge{
		Inputs: func(seed uint64) []string {
			out := []string{}
			for i := 0; i < 5; i++ {
				out = append(out, "x"+string(rune('a'+int((seed>>(i*8))%26))))
			}
			return out
		},
		Check: func(in, out string) bool { return out == reverse(in) },
	}
	c, err := b.Post(PostParams{
		Title: "Judged reverse", Poster: poster, Reward: 50, Deadline: t0.Add(time.Hour),
		Window: time.Hour, Judge: judge, Cases: []Case{{"ab", "ba"}},
	}, t0)
	if err != nil {
		t.Fatal(err)
	}
	b.Commit(c.ID, bob, HashSolution("gno.land/r/b/x", "1"), 0, t0)
	a, _, _ := b.Reveal(c.ID, "gno.land/r/b/x", "1", hardcoded, t0)
	if a.State != Failed {
		t.Fatal("lookup table must fail generated inputs")
	}
	b.Commit(c.ID, alice, HashSolution("gno.land/r/a/x", "1"), 0, t0)
	a, pay, _ := b.Reveal(c.ID, "gno.land/r/a/x", "1", reverse, t0)
	if a.State != Passed || a.Report.Total != 6 || c.Winner != a {
		t.Fatalf("state %v report %+v", a.State, a.Report)
	}
	if len(pay) != 1 || pay[0].Amount != 50 {
		t.Fatalf("no bond, only the prize: %+v", pay)
	}
}

func TestBoost(t *testing.T) {
	b, c := newBoard(t)
	if err := b.Boost(c.ID, 500, t0); err != nil {
		t.Fatal(err)
	}
	if c.Reward != 1500 || c.Boosts != 500 {
		t.Fatal("boost not applied")
	}
	if err := b.Boost(c.ID, 0, t0); err != ErrBadBoostAmount {
		t.Fatal("zero boost should fail")
	}
	if err := b.Boost(c.ID, 1, t0.Add(48*time.Hour)); err != ErrNotOpen {
		t.Fatal("boost after deadline should fail")
	}
}

func TestIterateNewestFirst(t *testing.T) {
	b := &Board{}
	for i := 0; i < 3; i++ {
		b.Post(PostParams{Title: "c", Poster: poster, Reward: 1, Deadline: t0.Add(time.Hour), Window: time.Hour, Cases: []Case{{"a", "a"}}}, t0)
	}
	var ids []uint64
	b.Iterate(func(c *Challenge) bool { ids = append(ids, c.ID); return false })
	if len(ids) != 3 || ids[0] != 3 || ids[2] != 1 {
		t.Fatalf("ids %v", ids)
	}
}
