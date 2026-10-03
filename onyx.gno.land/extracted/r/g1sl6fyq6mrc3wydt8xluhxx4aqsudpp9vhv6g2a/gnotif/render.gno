package gnotif

import (
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// Render lists the triggers in declaration order.
func Render(path string) string {
	var b strings.Builder
	b.WriteString("# gnotif triggers\n\n")
	triggers.Iterate("", "", func(_ string, v any) bool {
		tr := v.(*Trigger)
		b.WriteString("- **" + tr.ID + "** " + sanitize.InlineText(tr.Target) + " · " + sanitize.InlineText(tr.Event))
		if tr.Param != "" {
			b.WriteString(" · param " + sanitize.InlineText(tr.Param))
		}
		if tr.Verified {
			b.WriteString(" · ✓ verified")
		}
		b.WriteString(" · by " + tr.Declarer.String() + "\n")
		return false
	})
	return b.String()
}
