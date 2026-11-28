package tavern

import (
	"chain/markdown"
	"strconv"
	"strings"
	"time"
)

// Render draws the tavern board: the running totals, the Regulars
// Board leaderboard, and the most recent guestbook signatures, newest
// first. Guestbook messages are user-supplied, so they are escaped for
// inline markdown before being written to the page.
func Render(path string) string {
	var b strings.Builder

	b.WriteString("# 🍺 Tavern Guestbook\n\n")
	b.WriteString("*A cozy corner of gno.land. Sign the guestbook, check in daily, " +
		"and earn your stool among the Regulars.*\n\n")
	b.WriteString("---\n\n")
	b.WriteString("**Guestbook signatures:** " + strconv.Itoa(totalSigns) +
		" · **Check-ins poured:** " + strconv.Itoa(totalCheckIns) +
		" · **Patrons on record:** " + strconv.Itoa(len(patrons)) +
		" · **Today:** " + formatDay(today()) + " (UTC)\n\n")

	b.WriteString("## 🏆 Regulars Board\n\n")
	if len(board) == 0 {
		b.WriteString("_No regulars yet — the first stool by the fire is yours._\n\n")
	} else {
		b.WriteString("| # | Regular | Streak (days) | Best streak | Visits |\n")
		b.WriteString("|---|---------|---------------|-------------|--------|\n")
		for i, a := range board {
			p := patrons[a]
			b.WriteString("| " + strconv.Itoa(i+1) +
				" | " + shortAddr(a) +
				" | " + strconv.Itoa(p.streak) +
				" | " + strconv.Itoa(p.best) +
				" | " + strconv.Itoa(p.total) + " |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## 📖 Latest in the Guestbook\n\n")
	if len(book) == 0 {
		b.WriteString("_The first page is still blank. Leave the first words._\n\n")
	} else {
		for i := len(book) - 1; i >= 0; i-- {
			e := book[i]
			b.WriteString("- **" + shortAddr(e.author) + "** · " + formatDay(e.day) +
				" — " + markdown.EscapeInline(e.msg) + "\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("---\n\n")
	b.WriteString("### Pull up a stool\n\n")
	b.WriteString("- **Sign the guestbook** — call `Sign` with a short message (one line, up to 140 characters).\n")
	b.WriteString("- **Check in daily** — call `CheckIn` once a day; back-to-back days build your streak.\n")
	b.WriteString("- **Climb the board** — the top 10 regulars, ranked by streak and then visits, are carved above the bar.\n")

	return b.String()
}

// formatDay renders a UTC day number as an ISO date.
func formatDay(day int64) string {
	return time.Unix(day*secondsPerDay, 0).UTC().Format("2006-01-02")
}
