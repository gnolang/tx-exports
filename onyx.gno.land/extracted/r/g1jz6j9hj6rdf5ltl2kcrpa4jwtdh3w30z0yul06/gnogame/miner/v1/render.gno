package miner

import (
	"strconv"
	"strings"
	"time"

	eco "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/gnogame/miner/v1"
)

// Render shows the current season (path ""), one season's results
// ("season/<n>") or one player's page ("<address>"). It reads the season
// records and at most one player; it never scans all players. Seasons keep
// no per-player index, so the result tables list results and how many
// players reached each, not who.
func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "season/") {
		n, err := strconv.Atoi(path[len("season/"):])
		if err != nil || n < 1 {
			return "# Not found\n\nNo such season.\n"
		}
		return renderSeason(n)
	}
	return renderPlayer(path)
}

// badgeRule explains the badge rule in one paragraph.
func badgeRule() string {
	return "**Badges.** Copper to Pearl are value thresholds. Sapphire and Diamond go by rank: Diamond to the top " +
		strconv.Itoa(eco.DiamondPct) + "% of a season's results (rounded up), Sapphire to the next ones up to the top " +
		strconv.Itoa(eco.RankPct) + "% in total. The percentages count the players who reached Copper (" +
		fmtInt(copperMin) + "); only results at or above the Pearl threshold (" + fmtInt(pearlMin) +
		") can take a rank badge. Equal results get the same badge, so a tie never pushes the share past " +
		strconv.Itoa(eco.DiamondPct) + "% (" + strconv.Itoa(eco.RankPct) + "%): the cutoff is the lowest result at which " +
		"no more players than that are at or above it. A season's results and badges are final at its end, to the " +
		"second; actions that reach the chain later do not count.\n\n"
}

// notice: the halt banner and the successor link, "" if neither.
func notice() string {
	s := ""
	if halted {
		s += "> **Halted:** " + haltReason + "\n>\n> Join and Collect are closed for good. Everything recorded so far " +
			"stays readable here; every player's last projection is their result.\n\n"
	}
	if successor != "" {
		s += "> **Next version:** the game continues at [" + successor + "](" + successor[len("gno.land"):] + ").\n\n"
	}
	return s
}

func renderHome() string {
	t := now()
	n := seasonAt(t)
	var b strings.Builder
	b.WriteString("# GnoGame · Miner\n\n")
	b.WriteString(notice())
	switch {
	case start == 0:
		b.WriteString("The first season has not started yet.\n\n")
	case n == 0:
		b.WriteString("Season 1 opens " + fmtTime(start) + ".\n\n")
	default:
		ss := seasonStartOf(n)
		day := int((t-ss)/eco.Day) + 1
		b.WriteString("Season **" + strconv.Itoa(n) + "** · day **" + strconv.Itoa(day) + " / " +
			strconv.Itoa(eco.Net.SeasonDays) + "** · ends " + fmtTime(ss+seasonMs) + ", results final at that second\n\n")
	}
	b.WriteString("Every value here is computed on chain: each Collect sends the player's logged actions, and this realm " +
		"replays them with `gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/gnogame/miner/v1`, the same economy " +
		"the game runs in the browser, then collects at block time.\n\n")

	if n > 0 {
		b.WriteString("## Season " + strconv.Itoa(n) + " · if it ended now\n\n")
		r := recOf(n)
		if r == nil || r.ladder.Players == 0 {
			b.WriteString("Nobody has played this season yet.\n\n")
		} else {
			writeResults(&b, r, cutsOf(n), TopN)
			b.WriteString("Results are projections: what each farm reaches by the season end if its player does nothing " +
				"more (mining stops when the monitoring window runs out).\n\n")
		}
		b.WriteString(badgeRule())
	}
	b.WriteString("Players: " + strconv.Itoa(players.Size()) + "\n\n")

	if n > 1 {
		b.WriteString("## Past seasons\n\n")
		for s := 1; s < n; s++ {
			r := recOf(s)
			if r == nil || r.ladder.Players == 0 {
				continue
			}
			c := cutsOf(s)
			b.WriteString("- [Season " + strconv.Itoa(s) + "](:season/" + strconv.Itoa(s) + ") · final · players " +
				strconv.Itoa(r.ladder.Players) + " · Diamond " + strconv.Itoa(c.NDiamond) +
				" · Sapphire " + strconv.Itoa(c.NSapphire) + "\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("---\n\nA [Hazen Network Solutions](https://hazennetworksolutions.com) game.\n")
	return b.String()
}

// writeResults writes a season's counts, cutoffs and its best results (at
// most rows distinct results of at least Pearl).
func writeResults(b *strings.Builder, r *seasonRec, c eco.Cuts, rows int) {
	l := &r.ladder
	d, ds := eco.Slots(l.Counted)
	b.WriteString("Players: " + strconv.Itoa(l.Players) + " · at Copper or above (N): " + strconv.Itoa(l.Counted) +
		" · at Pearl or above: " + strconv.Itoa(l.PearlPlus) + "\n\n")
	b.WriteString("- Diamond (at most " + strconv.Itoa(d) + "): ")
	if c.Diamond > 0 {
		b.WriteString("results of at least **" + fmtInt(float64(c.Diamond)) + "** · " + strconv.Itoa(c.NDiamond) + " players\n")
	} else {
		b.WriteString("nobody\n")
	}
	b.WriteString("- Sapphire (at most " + strconv.Itoa(ds) + " with Diamond): ")
	if c.Sapphire > 0 {
		b.WriteString("results of at least **" + fmtInt(float64(c.Sapphire)) + "** · " + strconv.Itoa(c.NSapphire) + " players\n\n")
	} else {
		b.WriteString("nobody\n\n")
	}
	if l.PearlPlus == 0 {
		return
	}
	b.WriteString("| # | Result | Players | Badge |\n|---|---|---|---|\n")
	above := 0
	l.Top(rows, func(v int64, k int) bool {
		b.WriteString("| " + strconv.Itoa(above+1) + " | " + fmtInt(float64(v)) + " | " + strconv.Itoa(k) + " | " +
			badgeName(eco.RankBadge(v, c)) + " |\n")
		above += k
		return false
	})
	b.WriteString("\n")
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

func renderSeason(n int) string {
	var b strings.Builder
	b.WriteString("# GnoGame · Miner · Season " + strconv.Itoa(n) + "\n\n")
	b.WriteString(notice())
	t := now()
	if start == 0 || n > seasonAt(t) {
		b.WriteString("This season has not started yet.\n")
		return b.String()
	}
	ss := seasonStartOf(n)
	end := ss + seasonMs
	b.WriteString(fmtTime(ss) + " – " + fmtTime(end) + "\n\n")
	if ended(n, t) {
		b.WriteString("**Final** since " + fmtTime(end) + ".\n\n")
	} else {
		b.WriteString("Running. Results are projections and badges are as if the season ended now; both are final at " +
			fmtTime(end) + ".\n\n")
	}
	r := recOf(n)
	if r == nil || r.ladder.Players == 0 {
		b.WriteString("Nobody played this season.\n")
		return b.String()
	}
	b.WriteString("## Results\n\n")
	writeResults(&b, r, cutsOf(n), SeasonRows)
	b.WriteString(badgeRule())
	return b.String()
}

func renderPlayer(key string) string {
	// only a valid address is echoed back into the page
	if !address(key).IsValid() {
		return "# Not found\n\nNo such page.\n"
	}
	var b strings.Builder
	b.WriteString("# " + key + "\n\n")
	b.WriteString(notice())
	v := players.Get(key)
	if v == nil {
		b.WriteString("This address has no farm on chain yet.\n")
		return b.String()
	}
	p := v.(*player)
	st := farmOf(p)
	badge := orDash(badgeName(eco.RankBadge(p.proj, cutsOf(p.season))))
	place := ""
	if r := recOf(p.season); r != nil && r.ladder.Players > 0 {
		ahead, tied := r.ladder.Place(p.proj)
		if tied < 1 {
			tied = 1
		}
		place = " · place **#" + strconv.Itoa(ahead+1)
		if tied > 1 {
			place += "–" + strconv.Itoa(ahead+tied)
		}
		place += "** of " + strconv.Itoa(r.ladder.Players)
	}
	b.WriteString("## Season " + strconv.Itoa(p.season) + "\n\n")
	if ended(p.season, now()) {
		b.WriteString("Ended. Final result: **" + fmtInt(float64(p.proj)) + "** · badge: **" + badge + "**" + place + ". " +
			"The farm enters the current season at the player's next Join or Collect.\n\n")
	} else {
		b.WriteString("- Projected result: **" + fmtInt(float64(p.proj)) + "** · badge if the season ended now: **" + badge + "**" + place + "\n")
		b.WriteString("- At the last Collect: value " + fmtInt(st.Value) + " · mined " + fmtInt(st.Mined) + " " + eco.Token +
			" · wallet " + fmtInt(st.Wallet) + " " + eco.Token + "\n")
		b.WriteString("- Facility: " + eco.Rooms[st.Room].Name + " · rigs: " + strconv.Itoa(len(st.Rigs)) +
			" · cards: " + strconv.Itoa(len(st.Cards)) + " · monitoring: " + strconv.Itoa(st.WatchHours()) + " h\n")
		b.WriteString("- Last Collect: " + fmtTime(p.lastCollect) + " · Collects: " + strconv.Itoa(p.collects) + "\n\n")
		b.WriteString("The projection is what the farm reaches by the season end (" + fmtTime(seasonEndOf(p.season)) +
			") if the player does nothing more; it is final then.\n\n")
	}
	b.WriteString("## History\n\n")
	if len(st.History) == 0 {
		b.WriteString("No finished season yet.\n")
		return b.String()
	}
	b.WriteString("| Season | Badge | Value | Facility |\n|---|---|---|---|\n")
	for i := len(st.History) - 1; i >= 0; i-- {
		h := st.History[i]
		b.WriteString("| [" + strconv.Itoa(h.Season) + "](:season/" + strconv.Itoa(h.Season) + ") | " + orDash(h.Badge) +
			" | " + fmtInt(h.Value) + " | " + eco.Rooms[h.Room].Name + " |\n")
	}
	return b.String()
}

// fmtInt rounds x and groups thousands: 1234567.6 -> "1,234,568".
func fmtInt(x float64) string {
	v := int64(eco.JSRound(x))
	neg := v < 0
	if neg {
		v = -v
	}
	s := strconv.FormatInt(v, 10)
	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	for i := 0; i < len(s); i++ {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func fmtTime(ms int64) string {
	return time.Unix(ms/1000, 0).UTC().Format("2006-01-02 15:04:05 UTC")
}
