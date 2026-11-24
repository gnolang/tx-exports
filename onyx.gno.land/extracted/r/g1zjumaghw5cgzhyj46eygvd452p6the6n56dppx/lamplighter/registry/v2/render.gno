package registry

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// pageSize is how many jobs one page of the dashboard lists.
const pageSize = 20

// execDeposit is the storage deposit limit the dashboard suggests for running
// a job: enough for a callback that updates its own state, far too little for
// one that tries to grow state at the runner's expense.
const execDeposit = "10000" + Denom

// Render serves the dashboard:
//
//	""         the first page of open jobs, recent runs, and how to take part
//	"page/<n>" a later page of open jobs
//	"job/<id>" one job in detail
func Render(path string) string {
	switch {
	case path == "":
		return renderHome(1)
	case strings.HasPrefix(path, "page/"):
		n, err := strconv.Atoi(strings.TrimPrefix(path, "page/"))
		if err != nil || n < 1 {
			return "# 404\n\nNot a page number."
		}
		return renderHome(n)
	case strings.HasPrefix(path, "job/"):
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "job/"), 10, 64)
		if err != nil {
			return "# 404\n\nNot a job id."
		}
		return renderJob(id)
	}
	return "# 404\n\nNothing here."
}

func renderHome(page int) string {
	now := time.Now().Unix()
	var b strings.Builder

	b.WriteString("# Lamplighter\n\n")
	b.WriteString("gno.land has no scheduler: a realm only runs when a transaction calls it. ")
	b.WriteString("This is where realms post work that has to happen on a schedule. ")
	b.WriteString("Anyone who runs a job once it is due is paid its reward in the same transaction.\n\n")
	b.WriteString("**" + plural(int64(jobs.Size()), "job") + "** · **" + plural(totalRuns, "run") +
		"** · **" + gnot(totalPaid) + "** paid out\n\n")

	b.WriteString("## Jobs\n\n")
	pages := (jobs.Size() + pageSize - 1) / pageSize
	switch {
	case jobs.Size() == 0:
		b.WriteString("No jobs. A realm posts one by calling `Register`; see the end of this page.\n\n")
	case page > pages:
		b.WriteString("No such page. [First page](" + homePath() + ")\n\n")
	default:
		b.WriteString("| # | Job | Posted by | Every | Next run | Reward | Oil | Runs |\n")
		b.WriteString("|---|---|---|---|---|---|---|---|\n")
		jobs.IterateByOffset((page-1)*pageSize, pageSize, func(_ string, v any) bool {
			j := v.(*job)
			b.WriteString("| [" + utoa(j.id) + "](" + jobPath(j.id) + ")" +
				" | [" + sanitize.TableCell(j.name) + "](" + jobPath(j.id) + ")" +
				" | " + realmLink(j.owner) +
				" | " + every(j.interval) +
				" | " + status(j, now) +
				" | " + gnot(j.reward) +
				" | " + gnot(j.balance) +
				" | " + itoa(j.runs) + " |\n")
			return false
		})
		b.WriteString("\n")
		if pages > 1 {
			b.WriteString("Page " + strconv.Itoa(page) + " of " + strconv.Itoa(pages))
			if page > 1 {
				b.WriteString(" · [previous](" + pagePath(page-1) + ")")
			}
			if page < pages {
				b.WriteString(" · [next](" + pagePath(page+1) + ")")
			}
			b.WriteString("\n\n")
		}
	}

	b.WriteString("## Recent runs\n\n")
	runs := recentRuns()
	if len(runs) == 0 {
		b.WriteString("Nobody has run a job yet.\n\n")
	} else {
		b.WriteString("| When | Job | Run by | Paid |\n|---|---|---|---|\n")
		for _, r := range runs {
			b.WriteString("| " + clock(r.at) +
				" | [" + utoa(r.job) + "](" + jobPath(r.job) + ")" +
				" | " + r.by.String() +
				" | " + gnot(r.reward) + " |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## Run jobs and get paid\n\n")
	b.WriteString("Open a job marked **due now** and run it: the reward lands in your account in the same transaction. ")
	b.WriteString("A bot can do it for you: it polls `DueJobs`, simulates each run, and only sends the ones that pay more than they cost.\n\n")
	b.WriteString("Running a job executes code written by the realm that posted it, and you pay the storage deposit for any state that code adds. ")
	b.WriteString("Always set a low limit, such as `-max-deposit " + execDeposit + "`, so that a hostile job cannot spend your coins on its own storage.\n\n")

	b.WriteString("## Post a job from your realm\n\n")
	b.WriteString("Register a callback when your realm is deployed, then fund the job. The callback must check that this realm is the caller and that the job is its own:\n\n")
	b.WriteString("```go\n")
	b.WriteString("import \"" + realmPath + "\"\n\n")
	b.WriteString("var job uint64\n\n")
	b.WriteString("func init(cur realm) {\n")
	b.WriteString("\t// first run in an hour, then every hour, paying 0.05 GNOT a run\n")
	b.WriteString("\tjob = registry.Register(cross(cur), \"Hourly settlement\",\n")
	b.WriteString("\t\ttime.Now().Unix()+3600, 3600, 50000, settle)\n")
	b.WriteString("}\n\n")
	b.WriteString("func settle(cur realm, id uint64) error {\n")
	b.WriteString("\tif cur.Previous().PkgPath() != registry.Path() || id != job {\n")
	b.WriteString("\t\treturn errors.New(\"not my job\")\n")
	b.WriteString("\t}\n")
	b.WriteString("\t// ... the work ...\n")
	b.WriteString("\treturn nil\n")
	b.WriteString("}\n")
	b.WriteString("```\n\n")
	b.WriteString("Anyone can add oil with `Fund`. A realm sends coins here and calls `Credit` for the same amount. ")
	b.WriteString("Oil belongs to the job: only the realm that posted it can `Cancel` it and say where the remainder goes.\n\n")
	b.WriteString("Posting a job locks a storage deposit for its state, from whoever sends that transaction. ")
	b.WriteString("Only `Cancel` removes a job, and the deposit is released to whoever sends that transaction, so cancel a job once it is done.\n")
	return b.String()
}

func renderJob(id uint64) string {
	j, ok := jobs.Get(key(id)).(*job)
	if !ok {
		if id > 0 && id < nextID {
			return "# Job " + utoa(id) + "\n\nThis job was cancelled.\n\n[All jobs](" + homePath() + ")\n"
		}
		return "# 404\n\nNo job " + utoa(id) + ".\n\n[All jobs](" + homePath() + ")\n"
	}
	now := time.Now().Unix()
	this := txlink.Realm(realmPath)

	var b strings.Builder
	b.WriteString("# Job " + utoa(j.id) + ": " + sanitize.InlineText(j.name) + "\n\n")
	b.WriteString("- **Posted by:** " + realmLink(j.owner) + "\n")
	b.WriteString("- **Status:** " + status(j, now) + "\n")
	b.WriteString("- **Schedule:** " + every(j.interval) + "\n")
	if !j.done {
		b.WriteString("- **Next run:** " + clock(j.nextDue) + "\n")
	}
	b.WriteString("- **Reward per run:** " + gnot(j.reward) + "\n")
	b.WriteString("- **Oil left:** " + gnot(j.balance) + " (" + plural(j.balance/j.reward, "run") + ")\n")
	b.WriteString("- **Runs so far:** " + itoa(j.runs) + "\n")
	if j.runs > 0 {
		b.WriteString("- **Last run:** " + clock(j.lastRun) + " by " + j.lastBy.String() + "\n")
	}
	b.WriteString("\n")

	if j.done {
		b.WriteString("This job ran once and is done. Its owner can cancel it to free its state.\n\n")
		b.WriteString("[All jobs](" + homePath() + ")\n")
		return b.String()
	}

	b.WriteString("## Run it\n\n")
	if notRunnable(j, now) == "" {
		b.WriteString("This job is due. [Run it and collect " + gnot(j.reward) + "](" + this.Call("Exec", "id", utoa(j.id)) + ")\n\n")
	} else {
		b.WriteString("This job cannot run right now: " + notRunnable(j, now) + ".\n\n")
	}
	b.WriteString("Running it executes code written by " + realmLink(j.owner) + ", and you pay the storage deposit for any state that code adds. ")
	b.WriteString("Add `-max-deposit " + execDeposit + "` to the command.\n\n")

	b.WriteString("## Add oil\n\n")
	switch {
	case j.interval != 0:
		b.WriteString("[Fund this job with 1 GNOT](" + this.NewLink("Fund").AddArgs("id", utoa(j.id)).SetSend("1000000"+Denom).URL() + ")\n\n")
	case j.balance < j.reward:
		// A job that runs once holds exactly one reward.
		need := j.reward - j.balance
		b.WriteString("[Fund this job with the " + gnot(need) + " it needs](" + this.NewLink("Fund").AddArgs("id", utoa(j.id)).SetSend(itoa(need)+Denom).URL() + ")\n\n")
	default:
		b.WriteString("This job runs once and already holds its reward.\n\n")
	}
	b.WriteString("Oil belongs to the job. Only the realm that posted it can cancel it, and that realm decides where the remainder goes.\n\n")
	b.WriteString("[All jobs](" + homePath() + ")\n")
	return b.String()
}

// status is the one-phrase state of a job at the given time.
func status(j *job, now int64) string {
	switch {
	case j.done:
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

// clock renders a unix time as UTC.
func clock(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04:05") + " UTC"
}

// gnot renders an ugnot amount as GNOT with up to six decimals.
func gnot(ugnot int64) string {
	whole := ugnot / 1000000
	frac := ugnot % 1000000
	if frac == 0 {
		return itoa(whole) + " GNOT"
	}
	f := pad(itoa(frac), 6)
	return itoa(whole) + "." + strings.TrimRight(f, "0") + " GNOT"
}

// plural renders a count with its noun: "1 run", "2 runs".
func plural(n int64, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return itoa(n) + " " + noun + "s"
}

// realmLink links to a realm, showing its path with any address shortened.
// The path comes from the chain, never from a user, so it needs no escaping.
func realmLink(pkgPath string) string {
	path := strings.TrimPrefix(pkgPath, "gno.land")
	parts := strings.Split(path, "/")
	for i, p := range parts {
		if len(p) == 40 && strings.HasPrefix(p, "g1") {
			parts[i] = p[:6] + "…" + p[len(p)-4:]
		}
	}
	return "[" + strings.Join(parts, "/") + "](" + path + ")"
}

func homePath() string {
	return strings.TrimPrefix(realmPath, "gno.land")
}

func jobPath(id uint64) string {
	return homePath() + ":job/" + utoa(id)
}

func pagePath(n int) string {
	if n <= 1 {
		return homePath()
	}
	return homePath() + ":page/" + strconv.Itoa(n)
}
