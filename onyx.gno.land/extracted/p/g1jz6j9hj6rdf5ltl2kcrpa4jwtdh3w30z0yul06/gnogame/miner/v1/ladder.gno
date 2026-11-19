package miner

import (
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// Rank badges (Sapphire and Diamond) of a season with many players, as an
// on-chain realm gives them. The JS game (and BadgeOf) uses fixed value
// thresholds for every badge; a shared season instead ranks its results:
//
//   - A result is a farm's season value, rounded (JSRound), as written to
//     its history entry.
//   - N is the number of results of at least Copper (100,000): farms that
//     only joined or barely played cannot create rank slots.
//   - Only results of at least Pearl (3,300,000) can get a rank badge.
//     Below Pearl the fixed thresholds apply (Copper … Pearl).
//   - Diamond: every result at or above the Diamond cutoff, the lowest
//     result at which no more than ceil(2%·N) results are at or above it.
//     Sapphire: every other result at or above the Sapphire cutoff, the
//     lowest result at which no more than ceil(5%·N) results (Diamond and
//     Sapphire together) are at or above it. Equal results always get the
//     same badge, so a tie that would overflow the share stays below it:
//     at most 2% (5%) of N qualify, never more.
//
// A Ladder keeps what this needs and no per-player entry: the counts and a
// histogram of the results of at least Pearl (rounded result -> number of
// players with it). Cuts walks the histogram from the top, at most
// ceil(5%·N)+1 entries.

const (
	DiamondPct = 2 // percent of N, rounded up
	RankPct    = 5 // Diamond and Sapphire together
)

var (
	CopperIdx   = badgeIdx("Copper")
	PearlIdx    = badgeIdx("Pearl")
	SapphireIdx = badgeIdx("Sapphire")
	DiamondIdx  = badgeIdx("Diamond")
	copperMinI  = int64(Badges[CopperIdx].Min)
	pearlMinI   = int64(Badges[PearlIdx].Min)
	bandMin     = bandMins() // Min of each badge below Pearl, by index
)

func bandMins() []int64 {
	m := make([]int64, PearlIdx)
	for i := 0; i < PearlIdx; i++ {
		m[i] = int64(Badges[i].Min)
	}
	return m
}

// bandOf is the fixed-threshold badge of a result in [Copper, Pearl).
func bandOf(v int64) int {
	b := CopperIdx
	for i := CopperIdx + 1; i < PearlIdx; i++ {
		if v >= bandMin[i] {
			b = i
		}
	}
	return b
}

func badgeIdx(name string) int {
	for i, b := range Badges {
		if b.Name == name {
			return i
		}
	}
	panic("no badge " + name)
}

// Ladder is one season's results for the rank rule. The zero value is an
// empty ladder. Change it only with Add, Remove and Move.
type Ladder struct {
	Players   int // results recorded, any value
	Counted   int // results of at least Copper: N of the rule
	PearlPlus int // results of at least Pearl
	hist      avl.Tree
	band      []int // results in [Copper, Pearl) by badge index (nil: none yet)
}

// Cuts is the outcome of the rank rule for a ladder: the lowest result
// that gets Diamond and Sapphire (0: nobody), and how many players get
// each.
type Cuts struct {
	Diamond, Sapphire   int64
	NDiamond, NSapphire int
}

// Slots: how many results may get Diamond, and Diamond or Sapphire, when
// n results count (ceil(n·2%), ceil(n·5%)).
func Slots(n int) (d, ds int) {
	return (n*DiamondPct + 99) / 100, (n*RankPct + 99) / 100
}

const ladderMax int64 = 999999999999999 // 15 digits

// ladderKey: fixed-width decimal, so keys sort like the results.
func ladderKey(v int64) string {
	if v > ladderMax {
		v = ladderMax
	}
	s := strconv.FormatInt(v, 10)
	return "000000000000000"[len(s):] + s
}

func keyResult(k string) int64 {
	var v int64
	for i := 0; i < len(k); i++ {
		v = v*10 + int64(k[i]-'0')
	}
	return v
}

// Add records a result.
func (l *Ladder) Add(v int64) {
	l.Players++
	l.count(v, 1)
}

// Remove takes back a result recorded with Add.
func (l *Ladder) Remove(v int64) {
	l.Players--
	l.count(v, -1)
}

// Move changes a recorded result from old to v.
func (l *Ladder) Move(old, v int64) {
	if old == v {
		return
	}
	l.count(old, -1)
	l.count(v, 1)
}

func (l *Ladder) count(v int64, d int) {
	if v < copperMinI {
		return
	}
	l.Counted += d
	if v < pearlMinI {
		if l.band == nil {
			l.band = make([]int, PearlIdx)
		}
		l.band[bandOf(v)] += d
		return
	}
	l.PearlPlus += d
	k := ladderKey(v)
	n := d
	if x := l.hist.Get(k); x != nil {
		n += x.(int)
	}
	if n <= 0 {
		l.hist.Remove(k)
		return
	}
	l.hist.Set(k, n)
}

// Cuts applies the rank rule to the ladder as it is now.
func (l *Ladder) Cuts() Cuts {
	var c Cuts
	d, ds := Slots(l.Counted)
	cum := 0
	l.hist.ReverseIterate("", "", func(k string, x any) bool {
		n := cum + x.(int)
		if n > ds {
			return true
		}
		v := keyResult(k)
		if n <= d {
			c.Diamond = v
			c.NDiamond = n
		}
		c.Sapphire = v
		cum = n
		return false
	})
	if c.Sapphire == c.Diamond {
		c.Sapphire = 0 // nobody between the cutoffs
	} else {
		c.NSapphire = cum - c.NDiamond
	}
	return c
}

// Top calls cb for the best results, best first, at most n distinct ones,
// with the number of players at each; it stops when cb returns true. Only
// results of at least Pearl are kept.
func (l *Ladder) Top(n int, cb func(v int64, players int) bool) {
	l.hist.ReverseIterateByOffset(0, n, func(k string, x any) bool {
		return cb(keyResult(k), x.(int))
	})
}

// Place is where result v stands among the recorded results: ahead, how
// many are better; tied, how many share v's place, v itself included when
// it is recorded. At or above Pearl a place is one result (the histogram
// is exact); below it the ladder keeps only a count per fixed badge, so the
// place is v's badge band (Copper … Topaz), or the results below Copper.
// It walks the histogram entries at or above v (at most the Pearl results).
func (l *Ladder) Place(v int64) (ahead, tied int) {
	if v < copperMinI {
		return l.Counted, l.Players - l.Counted
	}
	if v < pearlMinI {
		b := bandOf(v)
		ahead = l.PearlPlus
		if l.band != nil {
			n := len(l.band)
			for i := b + 1; i < n; i++ {
				ahead += l.band[i]
			}
			tied = l.band[b]
		}
		return ahead, tied
	}
	k := ladderKey(v)
	l.hist.ReverseIterate(k, "", func(key string, x any) bool {
		if key == k {
			tied = x.(int)
		} else {
			ahead += x.(int)
		}
		return false
	})
	return ahead, tied
}

// RankBadge is the badge (index into Badges, -1 for none) of result v
// under the cutoffs c.
func RankBadge(v int64, c Cuts) int {
	if v >= pearlMinI {
		switch {
		case c.Diamond > 0 && v >= c.Diamond:
			return DiamondIdx
		case c.Sapphire > 0 && v >= c.Sapphire:
			return SapphireIdx
		}
		return PearlIdx
	}
	b := -1
	for i := 0; i < PearlIdx; i++ {
		if v >= int64(Badges[i].Min) {
			b = i
		}
	}
	return b
}
