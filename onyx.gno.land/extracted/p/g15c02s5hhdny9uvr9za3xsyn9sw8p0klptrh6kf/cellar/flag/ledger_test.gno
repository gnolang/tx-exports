package flag

import "testing"

const (
	ash   = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")
	briar = address("g19cyxvfmzdnxlf4ul6328wqq4hy3ssqmqcgul0k")
	cask  = address("g1rh0vd3xzwjpcqehrf0tpjlqeq35079wf4zklar")
)

func TestLedgerRecord(t *testing.T) {
	l := NewLedger()
	if l.Captured(ash) {
		t.Fatal("empty ledger reports a capture")
	}
	c, fresh := l.Record(ash)
	if !fresh || c.Order != 1 || c.Player != ash {
		t.Fatalf("first record = %+v, fresh=%v", c, fresh)
	}
	testing.SkipHeights(3)
	again, fresh := l.Record(ash)
	if fresh || again != c {
		t.Fatalf("second record of same player should return the first: %+v", again)
	}
	c2, _ := l.Record(briar)
	if c2.Order != 2 || c2.Height != c.Height+3 {
		t.Fatalf("second player capture = %+v", c2)
	}
	if l.Count() != 2 || !l.Captured(briar) || l.Captured(cask) {
		t.Fatal("count or membership wrong")
	}
}

func TestLedgerRecent(t *testing.T) {
	l := NewLedger()
	if got := l.Recent(5); len(got) != 0 {
		t.Fatalf("Recent on empty ledger = %v", got)
	}
	l.Record(ash)
	l.Record(briar)
	l.Record(cask)
	got := l.Recent(2)
	if len(got) != 2 || got[0].Player != cask || got[1].Player != briar {
		t.Fatalf("Recent(2) = %+v", got)
	}
	if len(l.Recent(10)) != 3 {
		t.Fatal("Recent should clamp to the ledger size")
	}
}
