package sugarproxy

import (
	"strconv"
	"strings"
	"time"
)

// Render shows the rules as people read them on gno.land.
func Render(path string) string {
	now := time.Now().Unix()
	var b strings.Builder
	b.WriteString("# sugar proxy\n\nHome internet connections, shared on purpose and paid in GNOT. Sharers run the sugar proxy app; " +
		"it carries only what these rules allow, checked against this realm through a light client. See sugar.video/proxy.\n\n")
	if paused {
		b.WriteString("**Paused.** Apps carry nothing until GovDAO or the guardian resumes it.\n\n")
	}
	sections := []struct{ kind, title string }{
		{KindSite, "Sites"}, {KindCustomer, "Customers"}, {KindRelease, "App releases"}, {KindHub, "Hubs"}, {KindPayer, "Payers"},
	}
	for _, s := range sections {
		b.WriteString("## " + s.title + "\n\n")
		n := 0
		for _, it := range items {
			if it.Kind != s.kind {
				continue
			}
			n++
			b.WriteString("- **" + strconv.Itoa(it.ID) + "** `" + joinFields(it.Fields) + "`: ")
			switch {
			case it.State != StateApproved:
				b.WriteString(it.Note)
			case now < it.After:
				b.WriteString("approved by " + it.By + "; counts from " + time.Unix(it.After, 0).UTC().Format(time.RFC3339) +
					" unless vetoed")
			default:
				b.WriteString("counts (approved by " + it.By + ")")
			}
			b.WriteString("\n")
		}
		if n == 0 {
			b.WriteString("None yet.\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("## Who decides\n\n")
	b.WriteString("- SUGAR holders, by the governor: propose `" + kindAdd + "` with `kind|field|...`, or `" + kindRemove + "` with an item's number.\n")
	if delegate != "" {
		b.WriteString("- The delegate realm `" + delegate + "` adds and removes sites.\n")
	} else {
		b.WriteString("- No delegate realm is named.\n")
	}
	b.WriteString("- GovDAO adds and removes anything at once, vetoes, pauses, and names the delegate and the guardian.\n")
	if guardian != "" {
		b.WriteString("- The guardian, " + guardian.String() + ", may veto and pause.\n")
	}
	b.WriteString("- Veto windows: sites " + days(vetoWin[KindSite]) + ", releases " + days(vetoWin[KindRelease]) + ", hubs, customers and payers " +
		days(vetoWin[KindHub]) + ".\n\n")
	open := 0
	for _, r := range requests {
		if !r.Done {
			if open == 0 {
				b.WriteString("## Suggestions\n\n")
			}
			open++
			b.WriteString("- " + strconv.Itoa(r.ID) + " `" + r.Payload + "` by " + r.By.String() + ": " + r.Reason + "\n")
		}
	}
	if open > 0 {
		b.WriteString("\n")
	}
	if len(payouts) > 0 {
		var paid int64
		for _, p := range payouts {
			paid += p.Ugnot
		}
		b.WriteString("## Payouts\n\n" + strconv.Itoa(len(payouts)) + " payouts, " + strconv.FormatInt(paid/1_000_000, 10) + " GNOT in all.\n\n")
	}
	b.WriteString("The rules apps read: params `doc`, sha256 " + digest + ", version " + strconv.Itoa(docSeq) + ".\n")
	return b.String()
}

func days(s int64) string {
	if s%86400 == 0 {
		return strconv.FormatInt(s/86400, 10) + " days"
	}
	return strconv.FormatInt(s/3600, 10) + " hours"
}
