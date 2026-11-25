package miner

import (
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// Season results of an on-chain realm. Every badge, Sapphire and Diamond
// included, is a fixed value threshold (Badges, the same as the JS game's
// BadgeOf): a result earns every badge whose threshold it reaches, however
// many other players do. Nobody else's account can take a badge away or
// add one (v2: v1 gave Sapphire and Diamond to the top 5% and 2% of a
// season, which clones could game, see docs/design.md).
//
//   - A result is a farm's season value, rounded (JSRound), as written to
//     its history entry.
//   - Counted: results of at least Copper (100,000).
//
// A Ladder keeps the counts and no per-player entry: a count per badge band
// below Pearl and a histogram of the results of at least Pearl (rounded
// result -> number of players with it) for places and the results table.

var (
	CopperIdx   = badgeIdx("Copper")
	PearlIdx    = badgeIdx("Pearl")
	SapphireIdx = badgeIdx("Sapphire")
	DiamondIdx  = badgeIdx("Diamond")
	copperMinI  = int64(Badges[CopperIdx].Min)
	pearlMinI   = int64(Badges[PearlIdx].Min)
	sapphireMin = int64(Badges[SapphireIdx].Min)
	diamondMin  = int64(Badges[DiamondIdx].Min)
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

// Ladder is one season's results. The zero value is an empty ladder.
// Change it only with Add, Remove and Move.
type Ladder struct {
	Players   int // results recorded, any value
	Counted   int // results of at least Copper
	PearlPlus int // results of at least Pearl
	hist      avl.Tree
	band      []int // results in [Copper, Pearl) by badge index (nil: none yet)
}

// Cuts: the Sapphire and Diamond thresholds and how many results reach
// them (Diamond results are not counted in NSapphire).
type Cuts struct {
	Diamond, Sapphire   int64
	NDiamond, NSapphire int
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

// Cuts counts the results at or above the Sapphire and Diamond thresholds.
// It walks the histogram from the top down to the Sapphire threshold.
func (l *Ladder) Cuts() Cuts {
	c := Cuts{Diamond: diamondMin, Sapphire: sapphireMin}
	l.hist.ReverseIterate(ladderKey(sapphireMin), "", func(k string, x any) bool {
		if keyResult(k) >= diamondMin {
			c.NDiamond += x.(int)
		} else {
			c.NSapphire += x.(int)
		}
		return false
	})
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

// RankBadge is the badge (index into Badges, -1 for none) of result v: the
// highest fixed threshold it reaches.
func RankBadge(v int64) int {
	b := -1
	for i := range Badges {
		if v >= int64(Badges[i].Min) {
			b = i
		}
	}
	return b
}
