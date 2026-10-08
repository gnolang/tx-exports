// Package blocks encodes a radio rotation, an ordered list of slots (an id
// and a duration), as strings the caller stores under its own keys: a header
// (slot count, total, one total per group), one group string per Size² slots
// (one sum per block) and one block string per Size slots. Appending is O(1),
// changing a slot rewrites one block, one group and the header, and finding
// the slot at a position in the loop scans the group totals, one group's sums
// and a single block: O(n/Size² + Size), flat up to about two million slots.
// Inside a block, ids and durations are packed as fixed-width base-64 digits
// (4 per id, 2 per duration): 6 bytes of deposit per slot.
package blocks

import "gno.land/p/nym-alexiscolin000/gnoradio/store/v0"

// Size is the number of slots per block.
const Size = 128

// MaxID and MaxDur are what the packed digits hold.
const (
	MaxID  = 1<<24 - 1 // 16,777,215
	MaxDur = 1<<12 - 1 // 4095 seconds
)

func checkSlot(id int, dur int64) {
	if id < 0 || id > MaxID {
		panic("blocks: id out of range")
	}
	if dur < 0 || dur > MaxDur {
		panic("blocks: duration out of range")
	}
}

const groupSlots = Size * Size // slots per group

// ---- Codec form: the same rotation over strings the caller stores ----
//
// A rotation is a header (slot count, total, one total per group), one group
// string per Size² slots (one sum per block) and one block string per Size
// slots (an id and a duration per slot). The caller keeps them under its own
// keys; Where names the group and block of a slot. Each function takes the
// strings one call touches and returns them updated, so a write costs the
// header, one group and one block whatever the length.

// MaxSlots is the longest rotation a header counts.
const MaxSlots = 1<<24 - 1

// Widths in base-64 digits.
const (
	nW    = 4 // header: slot count
	totW  = 6 // header: total, then each group's total
	sumW  = 4 // group: one block's sum
	slotW = 6 // block: id (4) and duration (2)
)

// add adds d to the number of width w at position at of s.
func add(s string, at, w int, d int64) string {
	return s[:at] + store.Fixed(store.Num(s, at, w)+d, w) + s[at+w:]
}

// Len is the number of slots of a rotation ("" is empty).
func Len(h string) int {
	if h == "" {
		return 0
	}
	return int(store.Num(h, 0, nW))
}

// Total is the sum of all durations.
func Total(h string) int64 {
	if h == "" {
		return 0
	}
	return store.Num(h, nW, totW)
}

// Where returns the group and block (counted from the start of the
// rotation) that hold slot i.
func Where(i int) (g, b int) { return i / groupSlots, i / Size }

// fit panics unless grp and blk are slot i's group and block in a rotation
// of n slots (i == n: where the next slot goes, "" when new).
func fit(n int, grp, blk string, i int) {
	g, b := Where(i)
	inG, inB := clamp(n-g*groupSlots, groupSlots), clamp(n-b*Size, Size)
	if len(grp) != (inG+Size-1)/Size*sumW || len(blk) != inB*slotW {
		panic("blocks: wrong group or block for this slot")
	}
}

func clamp(v, max int) int {
	if v < 0 {
		return 0
	}
	if v > max {
		return max
	}
	return v
}

// Slot returns the id and duration of slot i, from its block.
func Slot(blk string, i int) (int, int64) {
	k := i % Size
	if i < 0 || len(blk) < (k+1)*slotW {
		panic("blocks: index out of range")
	}
	return int(store.Num(blk, k*slotW, 4)), store.Num(blk, k*slotW+4, 2)
}

// Append adds a slot at the end. grp and blk are those of slot Len(h)
// (Where), "" when it starts a new one. It returns the three strings and
// the new slot's index.
func Append(h, grp, blk string, id int, dur int64) (string, string, string, int) {
	checkSlot(id, dur)
	n := Len(h)
	if n >= MaxSlots {
		panic("blocks: rotation full")
	}
	fit(n, grp, blk, n)
	if h == "" {
		h = store.Fixed(0, nW) + store.Fixed(0, totW)
	}
	if n%groupSlots == 0 {
		h += store.Fixed(0, totW)
	}
	if n%Size == 0 {
		grp += store.Fixed(0, sumW)
	}
	g, b := Where(n)
	blk += store.Fixed(int64(id), 4) + store.Fixed(dur, 2)
	grp = add(grp, b%Size*sumW, sumW, dur)
	h = add(add(add(h, 0, nW, 1), nW, totW, dur), nW+totW+g*totW, totW, dur)
	return h, grp, blk, n
}

// Set replaces slot i's id and duration (0 takes it out of the loop).
func Set(h, grp, blk string, i, id int, dur int64) (string, string, string) {
	checkSlot(id, dur)
	n := Len(h)
	if i < 0 || i >= n {
		panic("blocks: index out of range")
	}
	fit(n, grp, blk, i)
	_, old := Slot(blk, i)
	k := i % Size * slotW
	blk = blk[:k] + store.Fixed(int64(id), 4) + store.Fixed(dur, 2) + blk[k+slotW:]
	if d := dur - old; d != 0 {
		g, b := Where(i)
		grp = add(grp, b%Size*sumW, sumW, d)
		h = add(add(h, nW, totW, d), nW+totW+g*totW, totW, d)
	}
	return h, grp, blk
}

// PrefixBefore returns the total duration of slots 0..i-1 (0 <= i <= Len).
func PrefixBefore(h, grp, blk string, i int) int64 {
	n := Len(h)
	if i < 0 || i > n {
		panic("blocks: index out of range")
	}
	fit(n, grp, blk, i)
	g, b := Where(i)
	var p int64
	for j := 0; j < g; j++ {
		p += store.Num(h, nW+totW+j*totW, totW)
	}
	for j := 0; j < b%Size; j++ {
		p += store.Num(grp, j*sumW, sumW)
	}
	for j := 0; j < i%Size; j++ {
		p += store.Num(blk, j*slotW+4, 2)
	}
	return p
}

// Find is done in three steps, loading the group then the block between
// them: FindGroup, FindBlock, FindSlot. FindGroup returns the group playing
// at pos (0 <= pos < Total) and the position inside it; ok is false when pos
// is out of range.
func FindGroup(h string, pos int64) (g int, rest int64, ok bool) {
	if pos < 0 || pos >= Total(h) {
		return 0, 0, false
	}
	for at := nW + totW; at < len(h); at += totW {
		t := store.Num(h, at, totW)
		if pos < t {
			return (at - nW - totW) / totW, pos, true
		}
		pos -= t
	}
	panic("blocks: bad header")
}

// FindBlock returns the block of group g playing at rest, and the position
// inside it.
func FindBlock(grp string, g int, rest int64) (b int, r int64) {
	for j := 0; j*sumW < len(grp); j++ {
		s := store.Num(grp, j*sumW, sumW)
		if rest < s {
			return g*Size + j, rest
		}
		rest -= s
	}
	panic("blocks: bad group")
}

// FindSlot returns the slot of block b playing at rest, its id and the
// offset into it. Slots of duration 0 are never returned.
func FindSlot(blk string, b int, rest int64) (slot, id int, offset int64) {
	for k := 0; k*slotW < len(blk); k++ {
		d := store.Num(blk, k*slotW+4, 2)
		if rest < d {
			return b*Size + k, int(store.Num(blk, k*slotW, 4)), rest
		}
		rest -= d
	}
	panic("blocks: bad block")
}
