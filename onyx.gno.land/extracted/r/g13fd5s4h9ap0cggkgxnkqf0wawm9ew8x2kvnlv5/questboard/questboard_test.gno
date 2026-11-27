package questboard

import (
	"chain"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

var (
	poster     = address("g1poster00000000000000000000000000000000")
	adventurer = address("g1adventurer000000000000000000000000000")
	stranger   = address("g1stranger00000000000000000000000000000")
	realmAddr  = address("g1questboard000000000000000000000000000")
)

const (
	t0       int64 = 1700000000 // arbitrary "now" for tests
	reward   int64 = 5000000    // 5 GNOT
	deadline       = t0 + 86400 // one day after t0
)

// fakeBanker is an in-memory chain/banker.Banker that tracks ugnot
// balances per address, so payment flows can be tested without a chain.
type fakeBanker struct {
	balances map[address]int64
}

func newFakeBanker() *fakeBanker {
	return &fakeBanker{balances: map[address]int64{}}
}

func (f *fakeBanker) GetCoins(addr address) chain.Coins {
	if bal := f.balances[addr]; bal > 0 {
		return chain.NewCoins(chain.NewCoin("ugnot", bal))
	}
	return chain.Coins{}
}

func (f *fakeBanker) GetCoin(addr address, denom string) int64 {
	if denom != "ugnot" {
		return 0
	}
	return f.balances[addr]
}

func (f *fakeBanker) SendCoins(from, to address, amt chain.Coins) {
	amount := amt.AmountOf("ugnot")
	if f.balances[from] < amount {
		panic("fakeBanker: insufficient funds")
	}
	f.balances[from] -= amount
	f.balances[to] += amount
}

func (f *fakeBanker) TotalCoin(denom string) int64 { return 0 }

func (f *fakeBanker) IssueCoin(addr address, denom string, amount int64) {
	f.balances[addr] += amount
}

func (f *fakeBanker) RemoveCoin(addr address, denom string, amount int64) {
	f.balances[addr] -= amount
}

func resetState() {
	quests = nil
	escrowed = 0
}

func mustPanic(t *testing.T, what string, f func()) {
	defer func() {
		if recover() == nil {
			t.Fatalf("expected panic: %s", what)
		}
	}()
	f()
}

// postOne posts a valid quest as poster at t0 and returns its ID.
func postOne(t *testing.T) uint64 {
	id := postQuest(poster, "Slay the spam goblins", "Clear the cellar.", reward, deadline, reward, t0)
	if id != 1 {
		t.Fatalf("first quest ID = %d, want 1", id)
	}
	return id
}

// ---------------------------------------------------------------------------
// Posting
// ---------------------------------------------------------------------------

func TestPostQuestHappy(t *testing.T) {
	resetState()
	id := postOne(t)
	q := mustQuest(id)
	if q.Status != StatusOpen {
		t.Fatalf("status = %d, want Open", q.Status)
	}
	if q.Poster != poster || q.Reward != reward || q.Deadline != deadline {
		t.Fatalf("quest fields wrong: %+v", q)
	}
	if escrowed != reward {
		t.Fatalf("escrowed = %d, want %d", escrowed, reward)
	}
	if QuestCount() != 1 || OpenQuestCount() != 1 {
		t.Fatalf("counts wrong: total %d open %d", QuestCount(), OpenQuestCount())
	}
}

func TestPostQuestPaymentMustMatchExactly(t *testing.T) {
	resetState()
	mustPanic(t, "underpayment", func() {
		postQuest(poster, "T", "", reward, deadline, reward-1, t0)
	})
	mustPanic(t, "overpayment", func() {
		postQuest(poster, "T", "", reward, deadline, reward+1, t0)
	})
	mustPanic(t, "no payment", func() {
		postQuest(poster, "T", "", reward, deadline, 0, t0)
	})
	if QuestCount() != 0 {
		t.Fatalf("no quest should exist after rejected posts")
	}
}

func TestPostQuestValidation(t *testing.T) {
	resetState()
	mustPanic(t, "empty title", func() {
		postQuest(poster, "", "", reward, deadline, reward, t0)
	})
	mustPanic(t, "reward below minimum", func() {
		postQuest(poster, "T", "", minRewardUgnot-1, deadline, minRewardUgnot-1, t0)
	})
	mustPanic(t, "deadline in the past", func() {
		postQuest(poster, "T", "", reward, t0-1, reward, t0)
	})
	mustPanic(t, "deadline too far out", func() {
		postQuest(poster, "T", "", reward, t0+maxQuestSeconds+1, reward, t0)
	})
}

// ---------------------------------------------------------------------------
// Accept / complete
// ---------------------------------------------------------------------------

func TestAcceptQuest(t *testing.T) {
	resetState()
	id := postOne(t)
	acceptQuest(adventurer, id, t0)
	q := mustQuest(id)
	if q.Status != StatusAccepted || q.Adventurer != adventurer {
		t.Fatalf("after accept: %+v", q)
	}
	if OpenQuestCount() != 0 {
		t.Fatalf("open count should be 0 after accept")
	}
}

func TestAcceptQuestGuards(t *testing.T) {
	resetState()
	id := postOne(t)
	mustPanic(t, "poster accepts own quest", func() {
		acceptQuest(poster, id, t0)
	})
	mustPanic(t, "accept after deadline", func() {
		acceptQuest(adventurer, id, deadline+1)
	})
	acceptQuest(adventurer, id, t0)
	mustPanic(t, "double accept", func() {
		acceptQuest(stranger, id, t0)
	})
	mustPanic(t, "unknown quest", func() {
		acceptQuest(adventurer, 999, t0)
	})
}

func TestCompleteQuestPaysAdventurer(t *testing.T) {
	resetState()
	fb := newFakeBanker()
	id := postOne(t)
	// Simulate the escrowed reward sitting at the realm address.
	fb.IssueCoin(realmAddr, "ugnot", reward)
	acceptQuest(adventurer, id, t0)

	completeQuest(poster, id, fb, realmAddr)

	if got := fb.GetCoin(adventurer, "ugnot"); got != reward {
		t.Fatalf("adventurer balance = %d, want %d", got, reward)
	}
	if got := fb.GetCoin(realmAddr, "ugnot"); got != 0 {
		t.Fatalf("realm balance = %d, want 0", got)
	}
	if escrowed != 0 {
		t.Fatalf("escrowed = %d, want 0", escrowed)
	}
	if mustQuest(id).Status != StatusCompleted {
		t.Fatalf("status should be Completed")
	}
}

func TestCompleteQuestGuards(t *testing.T) {
	resetState()
	fb := newFakeBanker()
	id := postOne(t)
	fb.IssueCoin(realmAddr, "ugnot", reward)

	mustPanic(t, "complete an open (unaccepted) quest", func() {
		completeQuest(poster, id, fb, realmAddr)
	})
	acceptQuest(adventurer, id, t0)
	mustPanic(t, "complete by non-poster", func() {
		completeQuest(adventurer, id, fb, realmAddr)
	})
	mustPanic(t, "complete by stranger", func() {
		completeQuest(stranger, id, fb, realmAddr)
	})
}

// ---------------------------------------------------------------------------
// Cancel / refund
// ---------------------------------------------------------------------------

func TestCancelQuestRefundsPoster(t *testing.T) {
	resetState()
	fb := newFakeBanker()
	id := postOne(t)
	fb.IssueCoin(realmAddr, "ugnot", reward)

	cancelQuest(poster, id, fb, realmAddr)

	if got := fb.GetCoin(poster, "ugnot"); got != reward {
		t.Fatalf("poster refund = %d, want %d", got, reward)
	}
	if escrowed != 0 || mustQuest(id).Status != StatusCancelled {
		t.Fatalf("after cancel: escrowed %d status %d", escrowed, mustQuest(id).Status)
	}
}

func TestCancelQuestGuards(t *testing.T) {
	resetState()
	fb := newFakeBanker()
	id := postOne(t)
	fb.IssueCoin(realmAddr, "ugnot", reward)
	mustPanic(t, "cancel by non-poster", func() {
		cancelQuest(stranger, id, fb, realmAddr)
	})
	acceptQuest(adventurer, id, t0)
	mustPanic(t, "cancel an accepted quest", func() {
		cancelQuest(poster, id, fb, realmAddr)
	})
}

func TestClaimRefundAfterDeadline(t *testing.T) {
	resetState()
	fb := newFakeBanker()
	id := postOne(t)
	fb.IssueCoin(realmAddr, "ugnot", reward)
	acceptQuest(adventurer, id, t0) // even accepted quests are refundable after deadline

	mustPanic(t, "refund before deadline", func() {
		claimRefund(poster, id, deadline, fb, realmAddr)
	})
	claimRefund(poster, id, deadline+1, fb, realmAddr)

	if got := fb.GetCoin(poster, "ugnot"); got != reward {
		t.Fatalf("poster refund = %d, want %d", got, reward)
	}
	if mustQuest(id).Status != StatusExpired || escrowed != 0 {
		t.Fatalf("after refund: status %d escrowed %d", mustQuest(id).Status, escrowed)
	}
}

// ---------------------------------------------------------------------------
// Accounting invariant + rendering
// ---------------------------------------------------------------------------

func TestEscrowInvariantAcrossLifecycle(t *testing.T) {
	resetState()
	fb := newFakeBanker()
	id1 := postQuest(poster, "Q1", "", reward, deadline, reward, t0)
	id2 := postQuest(poster, "Q2", "", 2*reward, deadline, 2*reward, t0)
	id3 := postQuest(poster, "Q3", "", 3*reward, deadline, 3*reward, t0)
	fb.IssueCoin(realmAddr, "ugnot", 6*reward)
	if escrowed != 6*reward {
		t.Fatalf("escrowed = %d, want %d", escrowed, 6*reward)
	}
	acceptQuest(adventurer, id1, t0)
	completeQuest(poster, id1, fb, realmAddr) // pays out reward
	cancelQuest(poster, id2, fb, realmAddr)   // refunds 2*reward
	if escrowed != 3*reward {
		t.Fatalf("escrowed = %d, want %d (only Q3 still locked)", escrowed, 3*reward)
	}
	if fb.GetCoin(adventurer, "ugnot") != reward {
		t.Fatalf("adventurer paid wrong amount")
	}
	if fb.GetCoin(poster, "ugnot") != 2*reward {
		t.Fatalf("poster refunded wrong amount")
	}
	_ = id3
}

func TestRenderPages(t *testing.T) {
	resetState()
	postOne(t)
	home := Render("")
	if !strings.Contains(home, "Tavern Quest Board") || !strings.Contains(home, "Slay the spam goblins") {
		t.Fatalf("home render missing board content:\n%s", home)
	}
	detail := Render("quest/1")
	if !strings.Contains(detail, "5 GNOT") || !strings.Contains(detail, "OPEN") {
		t.Fatalf("detail render wrong:\n%s", detail)
	}
	if Render("quest/999") == "" || Render("nonsense") == "" {
		t.Fatalf("unknown routes must still render a page")
	}
}

func TestRenderSanitizesUserText(t *testing.T) {
	resetState()
	postQuest(poster, "# [click](http://evil) `now`", "desc", reward, deadline, reward, t0)
	home := Render("")
	if strings.Contains(home, "[click](") || strings.Contains(home, "`now`") {
		t.Fatalf("user markdown was not sanitized:\n%s", home)
	}
}

func TestFormatGNOT(t *testing.T) {
	cases := map[int64]string{
		0:       "0 GNOT",
		1000000: "1 GNOT",
		1500000: "1.5 GNOT",
		1234567: "1.234567 GNOT",
		1000:    "0.001 GNOT",
	}
	for in, want := range cases {
		if got := FormatGNOT(in); got != want {
			t.Fatalf("FormatGNOT(%d) = %q, want %q", in, got, want)
		}
	}
}
