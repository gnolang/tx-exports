package registry

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
)

// Render serves the dashboard:
//
//	""        every job, then the most recent runs
//	"job/<id>" one job in detail
func Render(path string) string {
	if strings.HasPrefix(path, "job/") {
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "job/"), 10, 64)
		if err != nil {
			return "# 404\n\nNot a job id."
		}
		return renderJob(id)
	}
	if path != "" {
		return "# 404\n\nNothing here."
	}
	return renderHome()
}

func renderHome() string {
	now := time.Now().Unix()
	var b strings.Builder

	b.WriteString("# Lamplighter\n\n")
	b.WriteString("Nothing on gno.land wakes a realm up. Here, realms post the work they need done on a schedule, ")
	b.WriteString("and anyone who runs a due job is paid its reward in the same transaction.\n\n")
	b.WriteString("**" + itoa(int64(jobs.Size())) + "** jobs · **" + itoa(totalRuns) + "** runs · **" + gnot(totalPaid) + "** paid out\n\n")

	b.WriteString("## Jobs\n\n")
	if jobs.Size() == 0 {
		b.WriteString("No jobs yet. A realm registers one by calling `Register`.\n\n")
	} else {
		b.WriteString("| # | Job | Owner | Every | Status | Reward | Oil | Runs | |\n")
		b.WriteString("|---|---|---|---|---|---|---|---|---|\n")
		jobs.Iterate("", "", func(_ string, v any) bool {
			j := v.(*Job)
			action := ""
			if notRunnable(j, now) == "" {
				action = "[Run it](" + txlink.Call("Exec", "id", utoa(j.id)) + ")"
			}
			b.WriteString("| [" + utoa(j.id) + "](" + jobPath(j.id) + ") | " + cell(j.name) +
				" | " + shortPath(j.owner) +
				" | " + every(j.interval) +
				" | " + status(j, now) +
				" | " + gnot(j.reward) +
				" | " + gnot(j.balance) +
				" | " + itoa(j.runs) +
				" | " + action + " |\n")
			return false
		})
		b.WriteString("\n")
	}

	b.WriteString("## Recent runs\n\n")
	runs := recentRuns()
	if len(runs) == 0 {
		b.WriteString("Nobody has run a job yet.\n")
	} else {
		b.WriteString("| When | Job | Run by | Paid |\n|---|---|---|---|\n")
		for _, r := range runs {
			b.WriteString("| " + time.Unix(r.at, 0).UTC().Format(time.RFC3339) +
				" | [" + utoa(r.job) + "](" + jobPath(r.job) + ")" +
				" | " + r.by.String() +
				" | " + gnot(r.reward) + " |\n")
		}
	}
	return b.String()
}

func renderJob(id uint64) string {
	j, ok := jobs.Get(key(id)).(*Job)
	if !ok {
		return "# 404\n\nNo job " + utoa(id) + "."
	}
	now := time.Now().Unix()

	var b strings.Builder
	b.WriteString("# Job " + utoa(j.id) + ": " + cell(j.name) + "\n\n")
	b.WriteString("- **Owner:** `" + j.owner + "`\n")
	b.WriteString("- **Status:** " + status(j, now) + "\n")
	b.WriteString("- **Schedule:** " + every(j.interval) + "\n")
	if !j.closed && !j.finished {
		b.WriteString("- **Next due:** " + time.Unix(j.nextDue, 0).UTC().Format(time.RFC3339) + "\n")
	}
	b.WriteString("- **Reward per run:** " + gnot(j.reward) + "\n")
	b.WriteString("- **Oil left:** " + gnot(j.balance))
	if j.reward > 0 {
		b.WriteString(" (" + itoa(j.balance/j.reward) + " runs)")
	}
	b.WriteString("\n")
	b.WriteString("- **Runs so far:** " + itoa(j.runs) + "\n")
	if j.runs > 0 {
		b.WriteString("- **Last run:** " + time.Unix(j.lastRun, 0).UTC().Format(time.RFC3339) + " by " + j.lastBy.String() + "\n")
	}
	b.WriteString("\n")

	if notRunnable(j, now) == "" {
		b.WriteString("[Run it now](" + txlink.Call("Exec", "id", utoa(j.id)) + ") · ")
	}
	if !j.closed && !j.finished {
		b.WriteString("[Add oil](" + txlink.NewLink("Fund").AddArgs("id", utoa(j.id)).SetSend("1000000"+Denom).URL() + ") · ")
	}
	b.WriteString("[All jobs](" + homePath() + ")\n")
	return b.String()
}

// status is the one-phrase state of a job at the given time.
func status(j *Job, now int64) string {
	switch {
	case j.closed:
		return "closed"
	case j.finished:
		return "done"
	case j.balance < j.reward:
		return "out of oil"
	case now >= j.nextDue:
		return "**due now**"
	}
	return "in " + span(j.nextDue-now)
}

func every(interval int64) string {
	if interval == 0 {
		return "once"
	}
	return span(interval)
}

// span renders a duration in seconds using its two largest units.
func span(s int64) string {
	units := []struct {
		n    int64
		name string
	}{{86400, "d"}, {3600, "h"}, {60, "m"}, {1, "s"}}

	out := ""
	parts := 0
	for _, u := range units {
		if s >= u.n && parts < 2 {
			out += itoa(s/u.n) + u.name
			s %= u.n
			parts++
		}
	}
	if out == "" {
		return "0s"
	}
	return out
}

// gnot renders an ugnot amount as GNOT with up to six decimals.
func gnot(ugnot int64) string {
	whole := ugnot / 1000000
	frac := ugnot % 1000000
	if frac == 0 {
		return itoa(whole) + " GNOT"
	}
	f := itoa(frac)
	for len(f) < 6 {
		f = "0" + f
	}
	return itoa(whole) + "." + strings.TrimRight(f, "0") + " GNOT"
}

// cell makes a user-supplied string safe inside a markdown table cell.
func cell(s string) string {
	s = strings.ReplaceAll(s, "|", "/")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "[", "(")
	s = strings.ReplaceAll(s, "]", ")")
	s = strings.ReplaceAll(s, "<", "(")
	s = strings.ReplaceAll(s, ">", ")")
	return s
}

func shortPath(pkgPath string) string {
	return "`" + strings.TrimPrefix(pkgPath, "gno.land") + "`"
}

func homePath() string {
	return strings.TrimPrefix(realmPath, "gno.land")
}

func jobPath(id uint64) string {
	return homePath() + ":job/" + utoa(id)
}
