package keepersboard

import (
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/jeronimoalbi/mdform/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/r/g1klfptn25xf37smf27vqr4g6qlmtwc0lz6y5mcj/heirloom/v1"
)

// Render shows the board, its keeper and the founder's will on Heirloom.
func Render(path string) string {
	if strings.Trim(path, "/") != "" {
		return "# Page not found\n\n[Back to the board](" + strings.TrimPrefix(pkgPath, runtime.ChainDomain()) + ")\n"
	}
	var b strings.Builder
	b.WriteString("# The Keeper's Board\n\n")
	b.WriteString("A small board that shows [Heirloom](" + heirloom.HomeURL() + ") at work; see [the founder's wills](" + heirloom.UserURL(founder) + "). ")
	b.WriteString("Anyone can post a note. The keeper can pin one note and remove any. ")
	b.WriteString("The keeper is `heirloom.Holder(founder)`: the founder, until a released will of the founder hands the board to a successor. ")
	b.WriteString("Every post, pin and removal is a sign of life on Heirloom for whoever signed it.\n\n")
	b.WriteString(keeperSection())
	b.WriteString(pinnedSection())
	b.WriteString(notesSection())
	b.WriteString(actionsSection())
	return b.String()
}

func keeperSection() string {
	keeper := Keeper()
	var b strings.Builder
	b.WriteString("## Keeper\n\n")
	b.WriteString("| Founder | Keeper now |\n| :--- | :--- |\n")
	b.WriteString("| " + userLink(founder) + " | " + userLink(keeper) + " |\n\n")
	if keeper != founder {
		b.WriteString("The founder's admin rights have passed on, so the board is now run by " + userLink(keeper) + ".\n\n")
		return b.String()
	}
	id, ok := heirloom.ActiveWill(founder)
	if !ok {
		b.WriteString("The founder has no unreleased will on Heirloom, so the board stays with the founder.\n\n")
		return b.String()
	}
	_, status, _, _ := heirloom.WillInfo(id)
	willLink := "[will " + strconv.Itoa(id) + "](" + heirloom.WillURL(id) + ")"
	switch status {
	case "due":
		b.WriteString("The founder's " + willLink + " is due: anyone but the founder can ask to release it now.\n\n")
	case "requested":
		b.WriteString("Someone asked to release the founder's " + willLink + ". Anyone can release it once the objection period ends, and until someone does, any sign of life from the founder cancels the request. The dates are on the will's page.\n\n")
	default:
		b.WriteString("If the founder stays silent for the whole silence period, anyone but the founder can ask to release the founder's " + willLink + ". The date is on the will's page.\n\n")
	}
	return b.String()
}

func pinnedSection() string {
	n, ok := notes.Get(noteKey(pinned)).(*note)
	if pinned == 0 || !ok {
		return ""
	}
	return "## Pinned\n\n" + noteLine(n) + "\n"
}

func notesSection() string {
	if notes.Size() == 0 {
		return "## Notes\n\nNo notes yet.\n\n"
	}
	var b strings.Builder
	b.WriteString("## Notes\n\n")
	count := 0
	notes.ReverseIterate("", "", func(_ string, v any) bool {
		b.WriteString(noteLine(v.(*note)))
		count++
		return count >= shownNotes
	})
	return b.String() + "\n"
}

func actionsSection() string {
	var b strings.Builder
	b.WriteString("## Post a note\n\n")
	b.WriteString(mdform.New("exec", "Post").
		Input("text", "placeholder", "Up to 280 characters", "description", "Note").
		String() + "\n\n")
	b.WriteString("## Keeper only\n\n")
	b.WriteString(mdform.New("exec", "Pin").Input("id", "type", mdform.InputTypeNumber, "description", "Note to pin").String() + "\n\n")
	b.WriteString(mdform.New("exec", "Remove").Input("id", "type", mdform.InputTypeNumber, "description", "Note to remove").String() + "\n")
	return b.String()
}

func noteLine(n *note) string {
	return ufmt.Sprintf("- #%d %s · %s, %s\n", n.ID, sanitize.InlineText(n.Text), userLink(n.Author), formatTime(n.At))
}

func userLink(addr address) string {
	s := addr.String()
	short := s
	if len(s) > 14 {
		short = s[:8] + "…" + s[len(s)-4:]
	}
	return "[" + short + "](" + heirloom.UserURL(addr) + ")"
}

func formatTime(t time.Time) string {
	return t.UTC().Format("2006-01-02 15:04 UTC")
}
