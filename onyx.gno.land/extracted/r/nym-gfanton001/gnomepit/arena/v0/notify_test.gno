package arena

import (
	"strings"
	"testing"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/r/nym-gfanton001/gnotif/v1"
)

func TestInitSetsTriggers(cur realm, t *testing.T) {
	ids := strings.Split(gnotif.Active(self), ",")
	urequire.Equal(t, 3, len(ids))
	want := [][6]string{ // name, event, param, title, body, link
		// The page opens the match a #match= fragment names.
		{"turn", "Turn", "to", "Your move in Gnomepit", "{text}", pagePath + "#match={match}"},
		{"ended", "Ended", "to", "Match over", "{text}", pagePath + "#match={match}"},
		{"board", "Board", "", "Gnomepit challenges", "{text}", pagePath},
	}
	for i, w := range want {
		page := gnotif.Render("trigger/" + ids[i])
		for j, label := range []string{"Name", "Event", "Param", "Title", "Body", "Link"} {
			// The registry renders each field through the same sanitizer.
			line := "- " + label + ": " + sanitize.InlineText(w[j]) + "\n"
			uassert.True(t, strings.Contains(page, line), ids[i]+" lacks "+line)
		}
	}
}
