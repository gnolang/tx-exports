package cutpurse

// render_profile.gno — one wallet's record. A record is the only reputation
// here, so it is stated plainly and never graded with a badge.

import (
	"strconv"
	"strings"
)

func renderProfile(addr string) string {
	var b strings.Builder
	b.WriteString(pageHead("A wallet", "", "The ledger", self("ledger")))
	if !address(addr).IsValid() {
		b.WriteString(notice("WARNING", "Not an address", "`"+text(addr)+"` is not a gno address."))
		return b.String() + nav("The ledger", self("ledger"), "Home", self(""))
	}

	jobs, escapes, busts, loot := StatsOf(addr)
	b.WriteString("## " + code(addr) + "\n\n")
	b.WriteString(cards(
		"**Jobs**\n\n"+strconv.FormatInt(jobs, 10),
		"**Escaped**\n\n"+strconv.FormatInt(escapes, 10),
		"**Busted**\n\n"+strconv.FormatInt(busts, 10),
		"**Secured**\n\n"+money(loot)+" GNOT",
	))
	b.WriteString("\n")

	if jobs == 0 {
		b.WriteString(notice("NOTE", "Nothing on this wallet yet",
			"A job takes five minutes and the ledger keeps it forever. "+
				md("Take a seat", self("jobs"))+" and this page fills itself in."))
		b.WriteString(nav("The board", self("jobs"), "Rules", self("rules")))
		return b.String()
	}

	b.WriteString(notice("NOTE", "Read the seats, not the percentage",
		"Escapes at a high fee beat many cheap jobs. Contribution is what each split was weighted by."))

	b.WriteString("## Jobs settled\n\n")
	rows := entriesOf(addr)
	if len(rows) == 0 {
		b.WriteString("_This wallet is in a live job and has not settled one yet._\n\n")
	} else {
		b.WriteString(resultTable(rows))
	}

	b.WriteString(button("Find a job", self("jobs"), "") + "\n\n")
	b.WriteString(nav("The ledger", self("ledger"), "Home", self("")))
	return b.String()
}

// entriesOf scans the archived ledger for one wallet. The ring buffer holds
// 500 entries, so one page is enough to find a recent record.
func entriesOf(addr string) []Result {
	var out []Result
	for p := 0; p <= currentLedgerPages(); p++ {
		for _, r := range ledgerPage(p, LedgerMax) {
			if strings.Contains(r.Payouts, addr) || r.Traitor.String() == addr {
				out = append(out, r)
			}
		}
	}
	return out
}
