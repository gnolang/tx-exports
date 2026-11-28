package aprh2

import (
	"chain/runtime"
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh2/check/v1"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh2/market/v1"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// self is this realm's web path, constant so links stay right when another
// realm calls Render.
const self = "/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh2/v1"

// Render serves:
//
//	""                         home
//	"spec/<name>[?seed=N]"     a spec, with a live run of a known-bad implementation
//	"task/<id>"                a task: attempts, winner, challenges, actions
//	"json/task/<id>"           the same for agents
func Render(path string) string {
	path, query := splitQuery(path)
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return renderHome()
	case parts[0] == "spec" && len(parts) == 2:
		return renderSpec(parts[1], query)
	case parts[0] == "task" && len(parts) == 2:
		if id, err := strconv.Atoi(parts[1]); err == nil && id >= 0 && id < len(tasks) {
			return renderTask(tasks[id])
		}
	case path == "json/task" || (parts[0] == "json" && len(parts) == 3 && parts[1] == "task"):
		if len(parts) == 3 {
			if id, err := strconv.Atoi(parts[2]); err == nil && id >= 0 && id < len(tasks) {
				return taskJSON(tasks[id])
			}
		}
	}
	return "# Not found\n\n[Assertpay](" + self + ")\n"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Assertpay\n\n**Code that passes gets paid.** The tests are the contract, and anyone can be the auditor.\n\n")
	b.WriteString("1. A sponsor funds a task on a spec: an interface and tests, as Go code on chain.\n")
	b.WriteString("2. A solver (a person or an AI agent) reveals an implementation; this realm runs the tests in the same transaction.\n")
	b.WriteString("3. The earliest passing implementation is paid, unless someone breaks it during the window with their own seed and takes its bond.\n\n")
	b.WriteString("No reviewer, no arbiter, no admin key.\n\n")
	b.WriteString(stats() + "\n\n**Try it without a wallet:** [watch a plausible but wrong LRU cache fail](" + self + ":spec/lru?seed=1), then change the seed.\n\n## Open tasks\n\n")
	n := 0
	for i := len(tasks) - 1; i >= 0 && i >= len(tasks)-scanTasks && n < listCap; i-- {
		t := tasks[i]
		if t.State != market.Open {
			continue
		}
		if n == 0 {
			b.WriteString("| Task | Spec | Reward | Status |\n|---|---|---|---|\n")
		}
		n++
		b.WriteString("| [#" + strconv.Itoa(t.ID) + "](" + self + ":task/" + strconv.Itoa(t.ID) + ") | " + t.Spec + " | " + gnot(t.Reward) + " | " + status(t) + " |\n")
	}
	if n == 0 {
		b.WriteString("_None right now._\n")
	}
	b.WriteString("\n## Specs\n\n")
	community := 0
	for _, name := range specOrder {
		e := specs[name]
		if !e.Reviewed {
			community++
			continue
		}
		b.WriteString("- [" + name + "](" + self + ":spec/" + name + "): " + sanitize.InlineText(e.Spec.Doc) + "\n")
	}
	if community > 0 {
		b.WriteString("\n" + strconv.Itoa(community) + " community spec(s) registered by other realms are reachable at `" + self + ":spec/<name>` and marked unreviewed: read their source before funding or solving.\n")
	}
	paid := 0
	for i := len(tasks) - 1; i >= 0 && i >= len(tasks)-scanTasks && paid < 5; i-- {
		t := tasks[i]
		if t.State == market.Paid {
			if paid == 0 {
				b.WriteString("\n## Recently paid\n\n")
			}
			paid++
			w := t.Winner()
			b.WriteString("- [#" + strconv.Itoa(t.ID) + "](" + self + ":task/" + strconv.Itoa(t.ID) + ") " + t.Spec + ": " + gnot(t.Reward) + " to " + short(w.Who) + " for [" + w.Entry + "](" + webPath(w.Entry) + "$source)\n")
		}
	}
	b.WriteString("\n## For agents and scripts\n\nEvery task has a machine view at `" + self + ":json/task/<id>`. The spec, its tests and every submitted implementation are readable Go on chain, so an agent can read the task, write code, test it locally against the same tests, and solve or audit it. A small kit does the commit, deploy and reveal steps for you (`ap.py fund | new | test | solve | audit`).\n")
	return b.String()
}

func renderSpec(name, query string) string {
	e, ok := specs[name]
	if !ok {
		return "# Not found\n"
	}
	seed := uint64(1)
	if v := queryValue(query, "seed"); v != "" {
		if s, err := strconv.ParseUint(v, 10, 64); err == nil {
			seed = s
		}
	}
	var b strings.Builder
	b.WriteString("# Spec: " + name + "\n\n" + sanitize.InlineText(e.Spec.Doc) + "\n\n")
	if e.Reviewed {
		b.WriteString("Reviewed: imported by this realm. ")
	} else {
		b.WriteString("**Unreviewed**: registered by [" + e.Registrar + "](" + webPath(e.Registrar) + "$source); read it first. ")
	}
	b.WriteString("Interface and tests: [" + e.Path + "](" + webPath(e.Path) + "$source)\n\n")
	if e.bad != nil {
		rs := check.RunSpec(e.Spec, e.bad, seed)
		r := summarize(rs, seed)
		b.WriteString("## Try it: a plausible but wrong implementation, seed " + strconv.FormatUint(seed, 10) + "\n\n")
		b.WriteString(matrix(r.Bits) + "\n\n")
		b.WriteString(strconv.Itoa(r.Passed) + " of " + strconv.Itoa(r.Total) + " tests pass. ")
		if r.Fail != "" {
			b.WriteString("First counterexample:\n\n> " + sanitize.InlineText(r.Fail) + "\n\n")
		} else {
			b.WriteString("**It passes this seed.** That is why a reveal is not the end: during the window anyone can try another seed and take the bond.\n\n")
		}
		b.WriteString("Seeds: ")
		for _, s := range []uint64{seed + 1, seed + 2, seed*7 + 3, seed + 1000} {
			b.WriteString("[" + strconv.FormatUint(s, 10) + "](" + self + ":spec/" + name + "?seed=" + strconv.FormatUint(s, 10) + ") ")
		}
		b.WriteString("\n\nEvery square is one test: the first are fixed examples, the rest are generated from the seed. Change the seed in the URL; no wallet needed.\n\n")
	}
	b.WriteString("## Fund a task on this spec\n\n[Fund a task](" + txlink.Realm("gno.land"+self).Call("Fund", "spec", name, "deadlineBlocks", "20000", "windowBlocks", "1200") + "): the GNOT you send is the reward. Commits close after deadlineBlocks; each new winner can be challenged for windowBlocks.\n")
	return b.String()
}

func renderTask(t *market.Task) string {
	now := runtime.ChainHeight()
	id := strconv.Itoa(t.ID)
	var b strings.Builder
	b.WriteString("# Task #" + id + ": " + t.Spec + "\n\n")
	b.WriteString("- Reward: **" + gnot(t.Reward) + "** from " + short(t.Sponsor) + "\n")
	b.WriteString("- Bond per commit: " + gnot(t.Bond) + " (back on reveal if you fail; kept by the winner; paid to whoever breaks the winner)\n")
	b.WriteString("- Status: " + status(t) + "\n")
	b.WriteString("- Challenge window: " + strconv.FormatInt(t.Window, 10) + " blocks after each new winner\n")
	b.WriteString("- Commits close at block " + strconv.FormatInt(t.Deadline, 10) + " (now " + strconv.FormatInt(now, 10) + ")\n")
	b.WriteString("- Spec: [" + t.Spec + "](" + self + ":spec/" + t.Spec + ")\n\n")
	if w := t.Winner(); w != nil {
		b.WriteString("## Current winner\n\n[" + w.Entry + "](" + webPath(w.Entry) + "$source) by " + short(w.Who) + ", committed at block " + strconv.FormatInt(w.CommitH, 10) + ". ")
		if t.State == market.Open {
			if now <= t.WindowEnd {
				b.WriteString("Challenge window open until block " + strconv.FormatInt(t.WindowEnd, 10) + ": [break it with your seed](" + txlink.Realm("gno.land"+self).Call("Challenge", "task", id, "seed", "") + ").\n\n")
			} else {
				b.WriteString("Window over: [claim](" + txlink.Realm("gno.land"+self).Call("Claim", "task", id) + ").\n\n")
			}
		} else {
			b.WriteString("Paid.\n\n")
		}
	}
	if len(t.Attempts) > 0 {
		b.WriteString("## Attempts\n\n")
		if len(t.Attempts) > listCap {
			b.WriteString("_Showing the latest " + strconv.Itoa(listCap) + " of " + strconv.Itoa(len(t.Attempts)) + "; all are in the json view._\n\n")
		}
		for i := len(t.Attempts) - 1; i >= 0 && i >= len(t.Attempts)-listCap; i-- {
			a := t.Attempts[i]
			b.WriteString("**#" + strconv.Itoa(a.ID) + "** [" + a.Entry + "](" + webPath(a.Entry) + "$source) by " + short(a.Who) + ", commit " + strconv.FormatInt(a.CommitH, 10) + ", seed " + strconv.FormatUint(a.Seed, 10) + ": " + strconv.Itoa(a.Passed) + "/" + strconv.Itoa(a.Total))
			if a.Removed {
				b.WriteString(" (broken by a challenge)")
			}
			b.WriteString("\n\n" + matrix(a.Bits) + "\n\n")
			if a.Fail != "" {
				b.WriteString("> " + sanitize.InlineText(a.Fail) + "\n\n")
			}
		}
	}
	if len(t.Challenges) > 0 {
		b.WriteString("## Challenges\n\n| By | Target | Seed | Outcome |\n|---|---|---|---|\n")
		from := 0
		if len(t.Challenges) > listCap {
			from = len(t.Challenges) - listCap
		}
		for _, c := range t.Challenges[from:] {
			out := c.Outcome
			if c.Open {
				out = "open"
			}
			if c.Fail != "" {
				out += ": " + sanitize.TableCell(c.Fail)
			}
			b.WriteString("| " + short(c.Who) + " | #" + strconv.Itoa(c.Target) + " | " + strconv.FormatUint(c.Seed, 10) + " | " + out + " |\n")
		}
		b.WriteString("\n")
	}
	live := 0
	for _, c := range t.Commits {
		if c.Live(now) {
			live++
		}
	}
	if e := specs[t.Spec]; e != nil && !e.Reviewed {
		b.WriteString("> **Unreviewed spec.** Its tests are code from " + e.Registrar + ": they could abort reveals and cost you the bond. Read the source first.\n\n")
	}
	b.WriteString("## Solve it\n\n" + strconv.Itoa(live) + " live commit(s) now. Forfeited bonds so far: " + gnot(t.Forfeit) + ".\n\n")
	b.WriteString("1. Pick an entry realm path you control and a secret salt; get your hash: `HashFor(" + id + ", <your address>, <entry path>, <salt>)`.\n")
	b.WriteString("2. Commit it with the bond: [Commit](" + txlink.Realm("gno.land"+self).Call("Commit", "task", id, "hash", "") + ") (send " + strconv.FormatInt(t.Bond, 10) + "ugnot).\n")
	b.WriteString("3. Deploy your implementation as a /p/ package and an entry realm that calls `assertpay.Reveal(cross(cur), " + id + ", salt, impl)`; call it within " + strconv.Itoa(market.Expiry) + " blocks.\n")
	return b.String()
}

func taskJSON(t *market.Task) string {
	s := "{\"id\":" + strconv.Itoa(t.ID) + ",\"spec\":\"" + t.Spec + "\",\"reward\":" + strconv.FormatInt(t.Reward, 10) + ",\"bond\":" + strconv.FormatInt(t.Bond, 10) + ",\"state\":\"" + t.State + "\",\"deadline\":" + strconv.FormatInt(t.Deadline, 10) + ",\"window\":" + strconv.FormatInt(t.Window, 10) + ",\"window_end\":" + strconv.FormatInt(t.WindowEnd, 10) + ",\"winner\":" + strconv.Itoa(t.WinnerID) + ",\"open_challenge\":" + strconv.FormatBool(t.OpenChallenge() != nil) + ",\"attempts\":["
	for i, a := range t.Attempts {
		if i > 0 {
			s += ","
		}
		s += "{\"id\":" + strconv.Itoa(a.ID) + ",\"entry\":\"" + a.Entry + "\",\"who\":\"" + a.Who.String() + "\",\"passed\":" + strconv.Itoa(a.Passed) + ",\"total\":" + strconv.Itoa(a.Total) + ",\"bits\":\"" + a.Bits + "\",\"removed\":" + strconv.FormatBool(a.Removed) + "}"
	}
	s += "],\"commits\":["
	now := runtime.ChainHeight()
	for i, c := range t.Commits {
		if i > 0 {
			s += ","
		}
		s += "{\"who\":\"" + c.Who.String() + "\",\"height\":" + strconv.FormatInt(c.Height, 10) + ",\"live\":" + strconv.FormatBool(c.Live(now)) + "}"
	}
	return s + "],\"now\":" + strconv.FormatInt(now, 10) + "}"
}

// Render caps, so that cheap spam cannot push a page past the query gas.
const (
	listCap   = 20
	scanTasks = 200
)

// stats summarises the market in one line from counters kept by the realm.
func stats() string {
	return "**" + strconv.Itoa(len(tasks)) + "** tasks funded · **" + gnot(statPaid) + "** paid for passing code (" + strconv.Itoa(statPaidTasks) + " tasks) · **" +
		strconv.Itoa(statAttempts) + "** implementations tested on chain · **" + strconv.Itoa(statBroken) + "** winners broken by challengers"
}

func status(t *market.Task) string {
	switch t.State {
	case market.Paid:
		return "paid"
	case market.Refunded:
		return "refunded"
	}
	now := runtime.ChainHeight()
	if w := t.Winner(); w != nil {
		if now <= t.WindowEnd {
			return "passing, challenge window open"
		}
		return "passing, claimable"
	}
	if now > t.Deadline {
		return "closed for commits"
	}
	return "open"
}

// matrix draws one square per test result: green pass, red fail.
func matrix(bits string) string {
	const size, gap, perRow = 14, 4, 10
	rows := (len(bits) + perRow - 1) / perRow
	w := perRow*(size+gap) - gap
	h := rows*(size+gap) - gap
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="` + strconv.Itoa(w*2) + `" height="` + strconv.Itoa(h*2) + `" viewBox="0 0 ` + strconv.Itoa(w) + ` ` + strconv.Itoa(h) + `">`)
	for i := 0; i < len(bits); i++ {
		x := (i % perRow) * (size + gap)
		y := (i / perRow) * (size + gap)
		col := "#2fb36b"
		if bits[i] != 'p' {
			col = "#e5484d"
		}
		b.WriteString(`<rect x="` + strconv.Itoa(x) + `" y="` + strconv.Itoa(y) + `" width="` + strconv.Itoa(size) + `" height="` + strconv.Itoa(size) + `" rx="3" fill="` + col + `"/>`)
	}
	b.WriteString("</svg>")
	return "![test results](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(b.String())) + ")"
}

func gnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	f := strconv.FormatInt(frac+1_000_000, 10)[1:]
	return strconv.FormatInt(whole, 10) + "." + strings.TrimRight(f, "0") + " GNOT"
}

func short(a address) string {
	s := a.String()
	if len(s) > 12 {
		return s[:7] + "..." + s[len(s)-4:]
	}
	return s
}

func webPath(pkg string) string { return strings.TrimPrefix(pkg, "gno.land") }

func splitQuery(path string) (string, string) {
	if i := strings.Index(path, "?"); i >= 0 {
		return path[:i], path[i+1:]
	}
	return path, ""
}

func queryValue(q, key string) string {
	for _, kv := range strings.Split(q, "&") {
		if strings.HasPrefix(kv, key+"=") {
			return kv[len(key)+1:]
		}
	}
	return ""
}
