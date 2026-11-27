package flag

import (
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
)

// Capture is the proof that a player broke a challenge.
type Capture struct {
	Player address
	Height int64 // block height of the capture
	Order  int   // 1 for the first capture of this challenge
}

// Ledger records captures for one challenge.
//
// Keep a Ledger in an unexported variable of your realm and never return a
// pointer to it: its methods mutate, and a method call on a leaked pointer
// commits under your realm's authority. (Challenge "rack" is about
// exactly that.)
type Ledger struct {
	captures *avl.Tree // address -> Capture
	order    []address // players in capture order
}

// NewLedger returns an empty Ledger.
func NewLedger() *Ledger {
	return &Ledger{captures: avl.NewTree()}
}

// Record stores a capture for player at the current height. It returns
// the stored capture and true, or the earlier capture and false if the
// player had already captured.
func (l *Ledger) Record(player address) (Capture, bool) {
	if prev, ok := l.Get(player); ok {
		return prev, false
	}
	c := Capture{
		Player: player,
		Height: runtime.ChainHeight(),
		Order:  len(l.order) + 1,
	}
	l.captures.Set(player.String(), c)
	l.order = append(l.order, player)
	return c, true
}

// Captured reports whether player has captured.
func (l *Ledger) Captured(player address) bool {
	return l.captures.Has(player.String())
}

// Get returns the capture of player, if any.
func (l *Ledger) Get(player address) (Capture, bool) {
	v := l.captures.Get(player.String())
	if v == nil {
		return Capture{}, false
	}
	return v.(Capture), true
}

// Count returns the number of distinct players who captured.
func (l *Ledger) Count() int { return len(l.order) }

// Recent returns up to n captures, newest first.
func (l *Ledger) Recent(n int) []Capture {
	if n > len(l.order) {
		n = len(l.order)
	}
	out := make([]Capture, 0, n)
	for i := len(l.order) - 1; i >= len(l.order)-n; i-- {
		c, _ := l.Get(l.order[i])
		out = append(out, c)
	}
	return out
}
