package flag

import (
	"strconv"
	"strings"
)

// Card renders the standard header of a challenge page: title, grade,
// category, number of captures and the brief. Authors use it at the top of
// their Render so every challenge in the cellar reads the same way.
func Card(info Info, l *Ledger) string {
	var b strings.Builder
	b.WriteString("# " + info.Title + "\n\n")
	b.WriteString("**" + info.Difficulty.String() + "** · " + info.Category)
	b.WriteString(" · " + strconv.Itoa(l.Count()) + " captured")
	b.WriteString(" · worth " + strconv.Itoa(Value(info.Difficulty, l.Count())) + " points\n\n")
	b.WriteString(info.Brief + "\n")
	return b.String()
}

// Captures renders the n most recent captures of l as a markdown list.
func Captures(l *Ledger, n int) string {
	recent := l.Recent(n)
	if len(recent) == 0 {
		return "*Nobody has broken it yet.*\n"
	}
	var b strings.Builder
	for _, c := range recent {
		b.WriteString("- `" + c.Player.String() + "` at block " + strconv.FormatInt(c.Height, 10))
		if c.Order == 1 {
			b.WriteString(" (first)")
		}
		b.WriteString("\n")
	}
	return b.String()
}
