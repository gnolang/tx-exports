package cutpurse

// render_jobs.gno — the board. Every open and live job, one row each, and the
// filters as paths so a shared link keeps its filter.

import (
	"strconv"
	"strings"
)

// boardJobs collects rows for a filter: 0 open, 1 committing, 2 revealing,
// 3 escaped, 4 busted, anything else every live phase.
func boardJobs(kind int64) []JobView {
	switch kind {
	case 0:
		return jobList(0, 40)
	case 1:
		return jobList(1, 40)
	case 2:
		return jobList(2, 40)
	case 3:
		return jobList(3, 32)
	case 4:
		return jobList(4, 32)
	}
	rows := jobList(0, 20)
	rows = append(rows, jobList(1, 20)...)
	return append(rows, jobList(2, 20)...)
}

func filterName(kind int64) string {
	switch kind {
	case 0:
		return "open"
	case 1:
		return "committing"
	case 2:
		return "revealing"
	case 3:
		return "escaped"
	case 4:
		return "busted"
	}
	return "live"
}

// jobTable is one row per job: enough to judge a fee in one glance, nothing
// that belongs on the job's own page.
func jobTable(rows []JobView) string {
	var b strings.Builder
	b.WriteString("| Job | State | Seats | Pot | Fee | Clock | |\n")
	b.WriteString("|---|---|---:|---:|---:|---|---|\n")
	for _, jv := range rows {
		b.WriteString("| " + jobLinkCell(jv) + " | " + phaseBadge(jv.Phase) +
			" | " + seatStrip(int64(jv.NSeats)) +
			" | " + money(jv.Pot) + " | " + money(jv.Fee) +
			" | " + clockCell(jv) +
			" | " + md(icon("arrow-right", "Open job"), jobLink(jv.ID)) + " |\n")
	}
	return b.String()
}

// jobLinkCell is a job's name as a link; jobTitle already escapes its pipes.
func jobLinkCell(jv JobView) string {
	return md(icon("door", "")+" "+jobTitle(jv), jobLink(jv.ID))
}

// clockCell is a job's remaining time in a table cell.
func clockCell(jv JobView) string {
	switch jv.Phase {
	case 3, 4:
		return "settled"
	}
	if jv.Deadline <= jv.Height {
		return "**passed**"
	}
	return strconv.FormatInt(jv.Deadline-jv.Height, 10) + " blk"
}

func renderJobs(kind int64) string {
	var b strings.Builder
	b.WriteString(pageHead("The board", "", "Home", hub))

	if kind > 4 {
		var links []string
		for _, k := range []int64{0, 1, 2, 3, 4} {
			links = append(links, md(filterName(k), self("jobs/"+strconv.FormatInt(k, 10))))
		}
		b.WriteString("Filter: **live** (showing every live phase) · " + strings.Join(links, " · ") + "\n\n")
	} else {
		var links []string
		for _, k := range []int64{0, 1, 2, 3, 4} {
			label := filterName(k)
			if k == kind {
				links = append(links, "**"+label+"**")
				continue
			}
			links = append(links, md(label, self("jobs/"+strconv.FormatInt(k, 10))))
		}
		b.WriteString("Filter: " + strings.Join(links, " · ") + " · " + md("live", self("jobs")) + "\n\n")
	}

	rows := boardJobs(kind)
	if len(rows) == 0 {
		b.WriteString(emptyBoard(kind))
	} else {
		b.WriteString(jobTable(rows) + "\n")
		b.WriteString(notice("TIP", "Fees are set by each creator",
			"A low fee is a cheap seat, not a weak crew. Check the pot before you judge a job."))
	}

	b.WriteString(button("Start a job", self(""), "outline") + "\n\n")
	b.WriteString(nav("Home", self(""), "How it works", self("rules")))
	return b.String()
}

func emptyBoard(kind int64) string {
	switch kind {
	case 3:
		return notice("NOTE", "Nobody has escaped yet", "Settled jobs land here forever. "+
			"When one does, its payouts are public.") + "\n"
	case 4:
		return notice("NOTE", "Nobody has been busted yet", "The first job to hit an alarm of 3 lands here.")
	}
	if kind == 0 {
		return notice("NOTE", "No job is open. Be the first through the door.",
			"Start one, then send the link to a second wallet. Two seats are enough to run a round.")
	}
	return notice("NOTE", "No job is "+filterName(kind)+" right now", "Try "+md("every live job", self("jobs"))+".")
}
