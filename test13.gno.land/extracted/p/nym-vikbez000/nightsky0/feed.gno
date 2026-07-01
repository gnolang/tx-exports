package nightsky

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// CaptureFeed is a bounded, newest-first collection of CaptureResult values
// backed by an avl.Tree. It is used for both a single telescope's history and
// the network-wide recent feed.
//
// Entries are keyed by a zero-padded, monotonically increasing sequence so the
// tree iterates in insertion order. Newest-first reads use ReverseIterate, and
// trimming removes the lowest key (the oldest entry). This avoids the O(n)
// slice-prepend the previous implementation paid on every insert, and only
// loads the search path on access instead of the whole collection.
type CaptureFeed struct {
	tree *avl.Tree
	seq  int
	max  int
}

// NewCaptureFeed creates a feed that keeps at most max entries.
func NewCaptureFeed(max int) *CaptureFeed {
	if max <= 0 {
		panic("capture feed size must be positive")
	}
	return &CaptureFeed{
		tree: avl.NewTree(),
		seq:  0,
		max:  max,
	}
}

// feedKey renders a sequence into a fixed-width key so that string ordering
// matches numeric ordering.
func feedKey(seq int) string {
	return ufmt.Sprintf("%020d", seq)
}

// Add inserts a capture as the newest entry and trims the oldest if the feed is
// over capacity.
func (f *CaptureFeed) Add(c CaptureResult) {
	f.seq++
	f.tree.Set(feedKey(f.seq), c)

	for f.tree.Size() > f.max {
		oldest, _ := f.tree.GetByIndex(0)
		f.tree.Remove(oldest)
	}
}

// Len returns the number of stored captures.
func (f *CaptureFeed) Len() int {
	return f.tree.Size()
}

// Latest returns the most recent capture, if any.
func (f *CaptureFeed) Latest() (CaptureResult, bool) {
	if f.tree.Size() == 0 {
		return CaptureResult{}, false
	}
	_, value := f.tree.GetByIndex(f.tree.Size() - 1)
	return value.(CaptureResult), true
}

// RemoveAt removes the index-th newest capture (0 = most recent). It reports
// whether a capture was removed. Used for moderation of individual entries.
func (f *CaptureFeed) RemoveAt(index int) bool {
	size := f.tree.Size()
	if index < 0 || index >= size {
		return false
	}
	// Newest-first index i maps to ascending-key index (size-1-i).
	key, _ := f.tree.GetByIndex(size - 1 - index)
	_, removed := f.tree.Remove(key)
	return removed
}

// IterateNewest calls cb for each capture from newest to oldest. Return true
// from cb to stop early.
func (f *CaptureFeed) IterateNewest(cb func(c CaptureResult) bool) {
	f.tree.ReverseIterate("", "", func(_ string, value any) bool {
		return cb(value.(CaptureResult))
	})
}
