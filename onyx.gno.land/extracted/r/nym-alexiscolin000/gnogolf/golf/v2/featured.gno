package golf

import (
	"strconv"
	"time"
)

// The records the hub puts forward (as the site's boards, web/lib/featured.ts,
// whose draw and rules these are): not the course ranking's top three, a few
// players worth racing today, each for a reason said beside them. One a
// player, drawn again each day (the same day, the same picks as the site's,
// but for the players the site's bot check hides: the chain knows none).

// featuredRead is how much of the course ranking the picks look at: its first
// page; podium, its first places, which get no card of their own.
const (
	featuredRead = 50
	podium       = 3
)

// pick is a player put forward, and why.
type pick struct {
	r    *row
	name string
	at   int // their place on the ranking
	tag  string
}

// today is the day, a number: the picks hold for it and change with it (block time).
func today() int64 { return time.Now().Unix() / 86400 }

// draw is a player's draw for a day: FNV-1a over their address, seeded with
// the day (featured.ts draw: the same numbers, so the same picks).
func draw(player string, day int64) uint32 {
	h := uint32(2166136261) ^ uint32(day)
	for i := 0; i < len(player); i++ {
		h = (h ^ uint32(player[i])) * 16777619
	}
	return h
}

// featured is up to n picks from the course ranking in mode m: a fast start (a
// third of the course or less, at par or better), the best average against par
// (a third of the course played, nine holes at least), and today's picks for
// the rest; never the first three places.
func featured(m, n int) []pick {
	// every named row read, the first three too (the best average is the
	// course's, as featured.ts takes it, whoever holds it), numbered as the
	// boards number them: a row whose name was deleted keeps no place
	var rows []pick
	walked, at := 0, 0
	ranks[m].Iterate("", "", func(_, p string) bool {
		walked++
		if name := nameOf(p); name != "" {
			at++
			rows = append(rows, pick{r: rowOf(m, p), name: name, at: at})
		}
		return walked >= featuredRead
	})
	course := slots.Size()
	third := course / 3
	perHole := func(r *row) float64 { return float64(r.strokes-r.par) / float64(r.holes) }
	var rising, many []pick
	for _, x := range rows {
		if x.r.holes > 0 && x.r.holes <= max1(third) && x.r.strokes <= x.r.par {
			rising = append(rising, x)
		}
		if x.r.holes >= nine(third) {
			many = append(many, x)
		}
	}
	var sharp []pick
	for _, x := range many {
		switch {
		case len(sharp) == 0 || perHole(x.r) < perHole(sharp[0].r):
			sharp = []pick{x}
		case perHole(x.r) == perHole(sharp[0].r):
			sharp = append(sharp, x)
		}
	}
	day := today()
	var out []pick
	used := map[string]bool{}
	take := func(from []pick, tag string, again bool) {
		for len(out) < n {
			best := -1
			for i, x := range from {
				if !used[x.r.player] && x.at > podium && (best < 0 || draw(x.r.player, day) < draw(from[best].r.player, day)) {
					best = i
				}
			}
			if best < 0 {
				return
			}
			x := from[best]
			used[x.r.player] = true
			x.tag = tag
			if tag == "Today's pick" && countTag(out, tag) > 0 {
				x.tag = "Also today"
			}
			out = append(out, x)
			if !again {
				return
			}
		}
	}
	take(rising, "Fast start", false)
	take(sharp, "Best average", false)
	take(rows, "Today's pick", true)
	return out
}

func countTag(ps []pick, tag string) int {
	n := 0
	for _, p := range ps {
		if p.tag == tag {
			n++
		}
	}
	return n
}

func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}

func nine(n int) int {
	if n < 9 {
		return 9
	}
	return n
}

// featuredRows is the hub's records to beat in mode m, as markdown lines.
func featuredRows(m int) string {
	s := ""
	for _, x := range featured(m, 3) {
		s += "- **" + x.tag + ":** " + md("@"+x.name, "/u/"+x.name) + ", " + count(x.r.holes, "hole") + " at " + vsPar(x.r.strokes-x.r.par) +
			" (#" + strconv.Itoa(x.at) + ") · " + md("race their ghosts", playURL+"?by="+x.r.player) + "\n"
	}
	return s
}
