package signalboard

import (
	"strconv"
	"strings"
	"testing"
)

// Valid bech32 test addresses (throwaway gnokey accounts created for
// these tests; they hold no funds of value).
const (
	authorA = address("g18hk5n6qmgtxqlljy5athr3u3xg669sqayrfv5z")
	authorB = address("g1t0sk56hrpldswzayqxclt2fr3k29vrl5lz7f9e")
)

// expectAbort asserts that f aborts. Panics raised inside a crossing
// function surface as aborts at the caller, which plain recover()
// cannot catch; the revive() builtin (enabled in testing mode) can.
func expectPanic(t *testing.T, name string, f func()) {
	t.Helper()
	if r := revive(f); r == nil {
		t.Fatalf("%s: expected abort, got none", name)
	}
}

func TestPostSignal(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(authorA))
	before := TotalSignals()
	id := PostSignal(cross(cur), "BTC/USDT", "long", "67250.50", "Breakout above resistance")
	if id == 0 {
		t.Fatal("expected non-zero signal id")
	}
	if TotalSignals() != before+1 {
		t.Fatalf("expected total signals %d, got %d", before+1, TotalSignals())
	}
	sig := findSignal(id)
	if sig == nil {
		t.Fatal("posted signal not found")
	}
	if sig.Asset != "BTC/USDT" || sig.Direction != "long" || sig.Status != StatusOpen {
		t.Fatalf("unexpected signal contents: %+v", sig)
	}
	if sig.Author != authorA {
		t.Fatalf("expected author %s, got %s", authorA, sig.Author)
	}
	st := authors[authorA]
	if st == nil || st.Posted < 1 {
		t.Fatalf("expected author stats posted>=1, got %+v", st)
	}
}

func TestPostSignalValidation(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(authorA))
	expectPanic(t, "bad direction", func() {
		PostSignal(cross(cur), "ETH/USDT", "sideways", "3500", "")
	})
	expectPanic(t, "empty asset", func() {
		PostSignal(cross(cur), "", "long", "3500", "")
	})
	expectPanic(t, "empty price", func() {
		PostSignal(cross(cur), "ETH/USDT", "long", "", "")
	})
	// Direction is case-insensitive and normalized.
	id := PostSignal(cross(cur), "ETH/USDT", "SHORT", "3500.00", "")
	if findSignal(id).Direction != "short" {
		t.Fatal("direction was not normalized to lowercase")
	}
	// Markdown metacharacters are stripped from stored free text.
	id2 := PostSignal(cross(cur), "XRP/USDT", "long", "2.50", "a|b [x](y)\nnext")
	note := findSignal(id2).Note
	if strings.ContainsAny(note, "|[]()\n") {
		t.Fatalf("note was not sanitized: %q", note)
	}
}

func TestResolveSignal(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(authorA))
	id := PostSignal(cross(cur), "SOL/USDT", "long", "172.40", "Momentum continuation")
	openBefore := OpenSignals()
	winsBefore := 0
	if st := authors[authorA]; st != nil {
		winsBefore = st.Won
	}

	// Another author must not resolve it.
	testing.SetRealm(testing.NewUserRealm(authorB))
	expectPanic(t, "resolve by non-author", func() {
		ResolveSignal(cross(cur), id, true)
	})

	// The author resolves it as won.
	testing.SetRealm(testing.NewUserRealm(authorA))
	ResolveSignal(cross(cur), id, true)
	if findSignal(id).Status != StatusWon {
		t.Fatal("signal not marked won")
	}
	if OpenSignals() != openBefore-1 {
		t.Fatal("open signal count did not decrease")
	}
	if authors[authorA].Won != winsBefore+1 {
		t.Fatalf("expected author wins=%d, got %d", winsBefore+1, authors[authorA].Won)
	}

	// Resolving twice must fail.
	expectPanic(t, "double resolve", func() {
		ResolveSignal(cross(cur), id, false)
	})
	// Unknown id must fail.
	expectPanic(t, "unknown id", func() {
		ResolveSignal(cross(cur), 999999, true)
	})
}

func TestResolveLost(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(authorB))
	postedBefore := 0
	if st := authors[authorB]; st != nil {
		postedBefore = st.Posted
	}
	id := PostSignal(cross(cur), "DOGE/USDT", "short", "0.31", "Fade the hype")
	ResolveSignal(cross(cur), id, false)
	if findSignal(id).Status != StatusLost {
		t.Fatal("signal not marked lost")
	}
	st := authors[authorB]
	if st.Lost != 1 || st.Posted != postedBefore+1 {
		t.Fatalf("unexpected author stats: %+v", st)
	}
}

func TestRender(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(authorA))
	id := PostSignal(cross(cur), "AVAX/USDT", "long", "39.20", "Render test signal")

	board := Render("")
	for _, want := range []string{"# SignalBoard", "Latest signals", "Author leaderboard", "BTC/USDT"} {
		if !strings.Contains(board, want) {
			t.Fatalf("board render missing %q", want)
		}
	}

	detail := Render("signal/" + strconv.FormatUint(id, 10))
	for _, want := range []string{"AVAX/USDT", "long", "39.20", "open"} {
		if !strings.Contains(detail, want) {
			t.Fatalf("detail render missing %q", want)
		}
	}

	if got := Render("signal/424242"); !strings.Contains(got, "not found") {
		t.Fatalf("expected not-found render, got %q", got)
	}
}
