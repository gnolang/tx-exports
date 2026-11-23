package cutpurse

// render_ledger.gno — the permanent record, and the network totals.
// The ledger is the game's memory: it is why a snitch is worth naming.

import (
	"strconv"
	"strings"
)

const ledgerPageSize = 8

func renderLedger(page int64) string {
	if page < 1 {
		page = 1
	}
	var b strings.Builder
	b.WriteString(pageHead("The ledger",
		"Every settled job, kept. Fees, splits and snitches, readable by anyone.", "Home", hub))

	rows := ledgerPage(int(page-1), ledgerPageSize)
	if len(rows) == 0 {
		if page > 1 {
			b.WriteString(notice("NOTE", "Past the last page", "Nothing archived here. ") +
				md("Back to page 1", self("ledger/1")) + ".\n\n")
		} else {
			b.WriteString(notice("NOTE", "Nothing archived. The first job to settle lands here.",
				md("Open a job", self(""))+" and give it three rounds."))
		}
		b.WriteString(nav("Home", self(""), "The board", self("jobs")))
		return b.String()
	}

	b.WriteString(resultTable(rows) + "\n")
	if page > 1 {
		b.WriteString(md(icon("arrow-left", "")+" newer", self("ledger/"+strconv.FormatInt(page-1, 10))) + " · ")
	}
	if ledgerPageSize*page < LedgerLen() {
		b.WriteString(md("older "+icon("arrow-right", ""), self("ledger/"+strconv.FormatInt(page+1, 10))))
	}
	b.WriteString("\n\nPage " + strconv.FormatInt(page, 10) + ". The ledger keeps the last " +
		strconv.Itoa(LedgerMax) + " results; older ones fall off the end.\n\n")

	b.WriteString(notice("NOTE", "Secured loot, not loot",
		"The loot column is what the crew raised. Only the secured part was ever paid out — "+
			"a bust keeps what reached the door."))
	b.WriteString(nav("Home", self(""), "Totals", self("stats")))
	return b.String()
}

// resultTable is the archive, one row per job.
func resultTable(rows []Result) string {
	var b strings.Builder
	// No payout column: it is the widest string on the page and it grows with
	// every row. The receipt lives on the job itself.
	b.WriteString("| Job | Name | Outcome | Raised | Snitch | Block |\n")
	b.WriteString("|---|---|---|---:|---|---:|\n")
	for _, r := range rows {
		b.WriteString("| " + md(strconv.FormatInt(r.JobID, 10), jobLink(r.JobID)) + " | " +
			pipe(resultName(r)) + " | " + outcomeCell(r) + " | " +
			money(r.Loot) + " | " + snitchCell(r) + " | " +
			strconv.FormatInt(r.At, 10) + " |\n")
	}
	return b.String() + "\n"
}

func resultName(r Result) string {
	if strings.TrimSpace(r.Name) == "" {
		return "Job " + strconv.FormatInt(r.JobID, 10)
	}
	return r.Name
}

func outcomeCell(r Result) string {
	if r.Busted {
		return icon("alarm", "busted") + " busted"
	}
	return icon("check-circle", "escaped") + " escaped"
}

// snitchCell names the snitch seat's wallet. who() already answers "—" for an
// unusable address, so the zero address is the only case worth a guard here.
func snitchCell(r Result) string {
	s := r.Traitor.String()
	if len(s) < 20 {
		return "—"
	}
	return who(s)
}

// secured is what a bust did not destroy. The archive keeps raised loot, so
// a busted row shows nothing secure.
func secured(r Result) int64 {
	if r.Busted {
		return 0
	}
	return r.Loot
}

// ----- stats -----

func renderStats() string {
	var b strings.Builder
	b.WriteString(pageHead("Totals", "What the realm has run, in aggregate.", "Home", hub))
	b.WriteString(notice("NOTE", "Nobody's numbers are graded here",
		"This page is the cellar's own tally. Per-wallet records are on their profiles."))

	open := int64(len(jobList(0, 40)))
	var escaped, busted, loot int64
	for p := 0; p <= currentLedgerPages(); p++ {
		for _, r := range ledgerPage(p, ledgerPageSize) {
			loot += r.Loot
			if r.Busted {
				busted++
			} else {
				escaped++
			}
		}
	}
	settled := escaped + busted

	b.WriteString(cards(
		"**Jobs opened**\n\n"+strconv.FormatInt(JobCount(), 10),
		"**Open now**\n\n"+strconv.FormatInt(open, 10),
		"**Settled**\n\n"+strconv.FormatInt(settled, 10),
		"**Loot raised**\n\n"+money(loot)+" GNOT",
	))
	b.WriteString("\n")

	if settled > 0 {
		bar := busted * 10 / settled
		b.WriteString("**Treasury** " + coins(Treasury()) + "\n\n")
		b.WriteString("**Busted** " + meter(bar, 10) + " " +
			strconv.FormatInt(busted*100/settled, 10) + "% of " + plural(settled, "settled job") + "\n\n")
		b.WriteString("### The snitch has been named\n\n")
		b.WriteString(plural(busted, "bust") + " out of " + plural(settled, "settled job") +
			". A bust pays the snitch 60% of the pot, so a snitch who is never caught is the " +
			"best-paid seat in the game.\n\n")
	} else {
		b.WriteString(notice("NOTE", "No job has settled yet",
			"These totals fill in as jobs finish. "+md("Open the first", self(""))+"."))
	}

	b.WriteString(button("The ledger", self("ledger"), "outline") + " " +
		button("The board", self("jobs"), "outline") + "\n\n")
	b.WriteString(nav("Home", self(""), "Rules", self("rules")))
	return b.String()
}

// currentLedgerPages is the last page index (0-based).
func currentLedgerPages() int {
	if LedgerLen() == 0 {
		return 0
	}
	return int((LedgerLen() - 1) / ledgerPageSize)
}
