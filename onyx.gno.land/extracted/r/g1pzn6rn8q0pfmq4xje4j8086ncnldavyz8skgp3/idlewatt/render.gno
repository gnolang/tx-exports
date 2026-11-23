package idlewatt

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
)

const pageSize = 10

// Render serves the gnoweb dashboard.
//
//	""                 network summary, live node cards, leaderboard, recent jobs
//	"nodes?page=N"      every node, paginated
//	"node/<id>"         one node, its jobs and operator actions
//	"operator/<g1addr>" one operator's nodes
//	"leaderboard"       full ranking
//	"jobs?page=N"       job history
//	"about"             what this is, and what it is not
func Render(path string) string {
	route, query := path, ""
	if i := strings.Index(path, "?"); i >= 0 {
		route, query = path[:i], path[i+1:]
	}
	now := time.Now()
	switch {
	case route == "":
		return renderHome(now)
	case route == "nodes":
		return renderNodes(now, pageParam(query))
	case strings.HasPrefix(route, "node/"):
		id, err := strconv.Atoi(strings.TrimPrefix(route, "node/"))
		if err != nil {
			return notFound()
		}
		return renderNode(now, id)
	case strings.HasPrefix(route, "operator/"):
		return renderOperator(now, strings.TrimPrefix(route, "operator/"))
	case route == "leaderboard":
		return renderLeaderboard(now, 50)
	case route == "jobs":
		return renderJobs(pageParam(query))
	case route == "about":
		return renderAbout()
	}
	return notFound()
}

// ---------------------------------------------------------------------------
// pages

func renderHome(now time.Time) string {
	var b strings.Builder
	b.WriteString("# <gno-icon name=\"lightning\" /> IdleWatt\n\n")
	b.WriteString("*Idle compute, put to work.* An on-chain registry and dashboard for home GPU boxes, CPU nodes and, someday, parked vehicles that want to rent spare capacity on decentralized compute networks like Akash.\n\n")
	b.WriteString(navBar())
	b.WriteString(disclaimer())

	// Network summary cards.
	online, available, driving := 0, 0, 0
	nodes.Iterate("", "", func(_ string, v any) bool {
		n := v.(*Node)
		if isOnlineAt(n, now) {
			online++
			if n.Mode == ModeAvailable {
				available++
			}
		}
		if n.Mode == ModeDriving {
			driving++
		}
		return false
	})
	b.WriteString("## Network\n\n")
	b.WriteString("<gno-columns>\n")
	b.WriteString(statCard("server", "Nodes", strconv.Itoa(nodes.Size()), strconv.Itoa(driving)+" out driving"))
	b.WriteString("<gno-columns-sep>\n")
	b.WriteString(statCard("signal", "Online now", strconv.Itoa(online), strconv.Itoa(available)+" ready for work"))
	b.WriteString("<gno-columns-sep>\n")
	b.WriteString(statCard("coins", "Simulated earnings", fmtUSD(totalGrossCents), strconv.Itoa(jobs.Size())+" jobs recorded"))
	b.WriteString("<gno-columns-sep>\n")
	b.WriteString(statCard("trophy", "Fairness pool", fmtUSD(poolCents), fmtUSD(poolPaidCents)+" shared so far"))
	b.WriteString("</gno-columns>\n\n")

	// Node cards, highest earners first.
	b.WriteString("## Nodes\n\n")
	if nodes.Size() == 0 {
		b.WriteString("No nodes yet. Be the first to register one below.\n\n")
	} else {
		var cards []string
		leaderboard.IterateByOffset(0, 6, func(_ string, v any) bool {
			nv := nodes.Get(padID(v.(int)))
			if nv != nil {
				cards = append(cards, nodeCard(nv.(*Node), now))
			}
			return false
		})
		b.WriteString(cardGrid(cards, 3))
		if nodes.Size() > 6 {
			b.WriteString("[See all " + strconv.Itoa(nodes.Size()) + " nodes](" + link("nodes") + ")\n\n")
		}
	}

	b.WriteString("## <gno-icon name=\"trophy\" /> Leaderboard\n\n")
	b.WriteString(leaderboardTable(now, 5))
	b.WriteString("[Full leaderboard](" + link("leaderboard") + ")\n\n")

	b.WriteString("## Recent jobs\n\n")
	b.WriteString(jobsTable(0, 5, -1))
	b.WriteString("[All jobs](" + link("jobs") + ")\n\n")

	b.WriteString(bonusSection(now))
	b.WriteString(registerForm())
	return b.String()
}

func renderNodes(now time.Time, page int) string {
	var b strings.Builder
	b.WriteString("# All nodes\n\n")
	b.WriteString(navBar())
	total := nodes.Size()
	if total == 0 {
		b.WriteString("No nodes yet.\n")
		return b.String()
	}
	b.WriteString("| # | Node | Type | Region | Power | Rate | Status | Earned |\n")
	b.WriteString("|---|---|---|---|---|---|---|---|\n")
	nodes.IterateByOffset((page-1)*pageSize, pageSize, func(_ string, v any) bool {
		n := v.(*Node)
		b.WriteString("| " + strconv.Itoa(n.ID) + " | [" + n.Name + "](" + link("node/"+strconv.Itoa(n.ID)) + ") | " +
			kindLabel(n.Kind) + " | " + n.Region + " | " + powerLabel(n.Power) + " | " + fmtUSD(n.RateCents) + "/h | " +
			statusOf(n, now) + " | " + fmtUSD(n.TotalCents()) + " |\n")
		return false
	})
	b.WriteString("\n" + pager("nodes", page, total))
	return b.String()
}

func renderNode(now time.Time, id int) string {
	v := nodes.Get(padID(id))
	if v == nil {
		return notFound()
	}
	n := v.(*Node)
	var b strings.Builder
	b.WriteString("# " + kindIcon(n.Kind) + " " + n.Name + "\n\n")
	b.WriteString(navBar())
	b.WriteString("<gno-columns>\n<gno-frame>\n")
	b.WriteString("### Status\n\n**" + statusOf(n, now) + "**\n\n")
	if n.LastHeartbeat.IsZero() {
		b.WriteString("No heartbeat yet.\n\n")
	} else {
		b.WriteString("Last heartbeat " + ago(now.Sub(n.LastHeartbeat)) + " (" + strconv.Itoa(n.HeartbeatCount) + " total)\n\n")
		if isOnlineAt(n, now) && n.LastHeartbeat.Sub(n.SessionStart) >= time.Minute {
			b.WriteString("Up for " + fmtDuration(n.LastHeartbeat.Sub(n.SessionStart)) + "\n\n")
		}
		if n.LastNote != "" {
			b.WriteString("Note: *" + n.LastNote + "*\n\n")
		}
	}
	b.WriteString("</gno-frame>\n<gno-columns-sep>\n<gno-frame>\n")
	b.WriteString("### Specs\n\n")
	b.WriteString("- Type: " + kindLabel(n.Kind) + "\n")
	b.WriteString("- Hardware: " + n.Hardware + "\n")
	b.WriteString("- Region: " + n.Region + "\n")
	b.WriteString("- Power: " + powerLabel(n.Power) + "\n")
	b.WriteString("- Rate: **" + fmtUSD(n.RateCents) + "/hour**\n\n")
	b.WriteString("</gno-frame>\n<gno-columns-sep>\n<gno-frame>\n")
	b.WriteString("### Earnings (simulated)\n\n")
	b.WriteString("- Jobs: " + strconv.Itoa(n.JobCount) + " (" + fmtDuration(time.Duration(n.JobMinutes)*time.Minute) + " of compute)\n")
	b.WriteString("- From jobs: " + fmtUSD(n.EarnedCents) + "\n")
	b.WriteString("- Fairness bonus: " + fmtUSD(n.BonusCents) + "\n")
	b.WriteString("- **Total: " + fmtUSD(n.TotalCents()) + "**\n")
	b.WriteString("- Rank: #" + strconv.Itoa(rankOf(n)) + " of " + strconv.Itoa(nodes.Size()) + "\n\n")
	b.WriteString("</gno-frame>\n</gno-columns>\n\n")

	b.WriteString("Operator: [" + shortAddr(n.Operator) + "](" + link("operator/"+n.Operator.String()) + ") · registered " + n.RegisteredAt.UTC().Format("Jan 2, 2006") + "\n\n")

	b.WriteString("## Operator actions\n\n")
	b.WriteString("Only this node's operator (" + shortAddr(n.Operator) + ") can sign these. Each button opens a prefilled transaction form.\n\n")
	sid := strconv.Itoa(n.ID)
	b.WriteString("<gno-button href=\"" + txlink.NewLink("Heartbeat").AddArgs("id", sid, "note", "").URL() + "\" label=\"Send heartbeat\" />\n")
	b.WriteString("<gno-button href=\"" + txlink.NewLink("SetAvailability").AddArgs("id", sid, "mode", ModeAvailable).URL() + "\" label=\"Parked and plugged in\" variant=\"success\" />\n")
	if n.Kind == KindVehicle {
		b.WriteString("<gno-button href=\"" + txlink.NewLink("SetAvailability").AddArgs("id", sid, "mode", ModeDriving).URL() + "\" label=\"Driving\" variant=\"warning\" />\n")
	}
	b.WriteString("<gno-button href=\"" + txlink.NewLink("SetAvailability").AddArgs("id", sid, "mode", ModePaused).URL() + "\" label=\"Pause\" variant=\"outline\" />\n")
	b.WriteString("<gno-button href=\"" + txlink.NewLink("RecordJob").AddArgs("id", sid, "workload", "llama-3.3-70b inference", "minutes", "60").URL() + "\" label=\"Record a simulated job\" variant=\"info\" />\n")
	b.WriteString("<gno-button href=\"" + txlink.NewLink("SetRate").AddArgs("id", sid, "rateCents", strconv.FormatInt(n.RateCents, 10)).URL() + "\" label=\"Change rate\" variant=\"outline\" />\n\n")

	b.WriteString("## Job history\n\n")
	b.WriteString(jobsTable(0, 20, n.ID))
	return b.String()
}

func renderOperator(now time.Time, addr string) string {
	var b strings.Builder
	b.WriteString("# Operator " + safeAddrText(addr) + "\n\n")
	b.WriteString(navBar())
	var cards []string
	prefix := addr + "/"
	byOperator.Iterate(prefix, prefix+"~", func(_ string, v any) bool {
		nv := nodes.Get(padID(v.(int)))
		if nv != nil {
			cards = append(cards, nodeCard(nv.(*Node), now))
		}
		return false
	})
	if len(cards) == 0 {
		b.WriteString("This address has no nodes.\n")
		return b.String()
	}
	b.WriteString(cardGrid(cards, 3))
	return b.String()
}

func renderLeaderboard(now time.Time, limit int) string {
	var b strings.Builder
	b.WriteString("# <gno-icon name=\"trophy\" /> Leaderboard\n\n")
	b.WriteString(navBar())
	b.WriteString("Ranked by simulated job earnings plus fairness-pool bonus.\n\n")
	b.WriteString(leaderboardTable(now, limit))
	return b.String()
}

func renderJobs(page int) string {
	var b strings.Builder
	b.WriteString("# Job history\n\n")
	b.WriteString(navBar())
	b.WriteString("> [!NOTE] Simulated\n> Jobs are self-reported by node operators for demo purposes. Earnings are computed by the realm from each node's rate and the job length; no money moves.\n\n")
	b.WriteString(jobsTable((page-1)*pageSize*2, pageSize*2, -1))
	b.WriteString(pager("jobs", page, (jobs.Size()+1)/2))
	return b.String()
}

func renderAbout() string {
	var b strings.Builder
	b.WriteString("# About IdleWatt\n\n")
	b.WriteString(navBar())
	b.WriteString("A home with a GPU box, a rooftop of solar, or a truck parked in the driveway all have compute and energy sitting idle most of the day. IdleWatt is a public registry where those nodes announce themselves, prove they are alive with signed heartbeats, flip between *parked & plugged in* and *driving*, and log the jobs they complete, so anyone can see what a neighbourhood-scale compute network would look like.\n\n")
	b.WriteString("### How it works\n\n")
	b.WriteString("1. **Register** a node with `RegisterNode`: name, type (home-gpu, vehicle, cpu), hardware, region, power source and an hourly rate in US cents.\n")
	b.WriteString("2. **Heartbeat** with `Heartbeat`. Every heartbeat is a transaction signed by the operator's key. A node is online for " + fmtDuration(onlineWindow) + " after its last heartbeat.\n")
	b.WriteString("3. **Toggle availability** with `SetAvailability`: available, driving (vehicles only) or paused.\n")
	b.WriteString("4. **Record jobs** with `RecordJob`. The realm computes earnings from the rate and minutes; operators cannot type in an amount.\n")
	b.WriteString("5. **Fairness pool.** 14% of every job goes into a pool that `DistributeBonus` (anyone, at most hourly) splits *equally* across every node that is online and available, big or small, inspired by AtomOne's Nakamoto Bonus.\n\n")
	b.WriteString(disclaimer())
	b.WriteString("Admin: " + shortAddr(admin) + " · registrations " + boolWord(!paused, "open", "paused") + "\n")
	return b.String()
}

// ---------------------------------------------------------------------------
// components

func navBar() string {
	return "[Home](" + link("") + ") · [Nodes](" + link("nodes") + ") · [Leaderboard](" + link("leaderboard") + ") · [Jobs](" + link("jobs") + ") · [About](" + link("about") + ")\n\n"
}

func disclaimer() string {
	return "> [!WARNING] Simulated data\n> Every node, heartbeat and job here is self-reported by its operator or simulated for this demo. IdleWatt has **no Tesla or Akash integration** and no hardware attestation yet, and the dollar figures are simulated, not payments.\n\n"
}

func statCard(icon, title, value, sub string) string {
	return "<gno-frame>\n<gno-icon name=\"" + icon + "\" /> " + title + "\n\n**" + value + "**\n\n" + sub + "\n</gno-frame>\n"
}

func nodeCard(n *Node, now time.Time) string {
	var b strings.Builder
	b.WriteString("<gno-frame>\n")
	b.WriteString("#### " + kindIcon(n.Kind) + " [" + n.Name + "](" + link("node/"+strconv.Itoa(n.ID)) + ")\n\n")
	b.WriteString("**" + statusOf(n, now) + "**\n\n")
	b.WriteString(n.Hardware + "\n\n")
	b.WriteString(n.Region + " · " + powerLabel(n.Power) + "\n\n")
	b.WriteString(fmtUSD(n.RateCents) + "/h · " + plural(n.JobCount, "job") + " · **" + fmtUSD(n.TotalCents()) + "** earned\n")
	b.WriteString("</gno-frame>\n")
	return b.String()
}

// cardGrid lays cards out in rows of perRow columns.
func cardGrid(cards []string, perRow int) string {
	var b strings.Builder
	for i := 0; i < len(cards); i += perRow {
		b.WriteString("<gno-columns>\n")
		for j := i; j < i+perRow; j++ {
			if j > i {
				b.WriteString("<gno-columns-sep>\n")
			}
			if j < len(cards) {
				b.WriteString(cards[j])
			} // else: an empty column keeps a short last row aligned
		}
		b.WriteString("</gno-columns>\n\n")
	}
	return b.String()
}

func leaderboardTable(now time.Time, limit int) string {
	if leaderboard.Size() == 0 {
		return "Nobody on the board yet.\n\n"
	}
	var b strings.Builder
	b.WriteString("| Rank | Node | Type | Jobs | From jobs | Bonus | Total |\n")
	b.WriteString("|---|---|---|---|---|---|---|\n")
	rank := 0
	leaderboard.IterateByOffset(0, limit, func(_ string, v any) bool {
		nv := nodes.Get(padID(v.(int)))
		if nv == nil {
			return false
		}
		n := nv.(*Node)
		rank++
		b.WriteString("| " + medal(rank) + " | [" + n.Name + "](" + link("node/"+strconv.Itoa(n.ID)) + ") | " + kindLabel(n.Kind) + " | " +
			strconv.Itoa(n.JobCount) + " | " + fmtUSD(n.EarnedCents) + " | " + fmtUSD(n.BonusCents) + " | **" + fmtUSD(n.TotalCents()) + "** |\n")
		return false
	})
	b.WriteString("\n")
	return b.String()
}

// jobsTable lists jobs newest first. nodeID < 0 means all nodes.
func jobsTable(offset, limit, nodeID int) string {
	var rows []*Job
	if nodeID < 0 {
		jobs.ReverseIterateByOffset(offset, limit, func(_ string, v any) bool {
			rows = append(rows, v.(*Job))
			return false
		})
	} else {
		prefix := padID(nodeID) + "/"
		nodeJobs.ReverseIterate(prefix, prefix+"~", func(_ string, v any) bool {
			jv := jobs.Get(padID(v.(int)))
			if jv != nil {
				rows = append(rows, jv.(*Job))
			}
			return len(rows) >= limit
		})
	}
	if len(rows) == 0 {
		return "No jobs yet.\n\n"
	}
	var b strings.Builder
	if nodeID < 0 {
		b.WriteString("| # | Node | Workload | Length | Earned | When (UTC) |\n|---|---|---|---|---|---|\n")
	} else {
		b.WriteString("| # | Workload | Length | Rate | Earned | To pool | When (UTC) |\n|---|---|---|---|---|---|---|\n")
	}
	for _, j := range rows {
		length := fmtDuration(time.Duration(j.Minutes) * time.Minute)
		when := j.CompletedAt.UTC().Format("Jan 2 15:04")
		if nodeID < 0 {
			b.WriteString("| " + strconv.Itoa(j.ID) + " | [" + j.NodeName + "](" + link("node/"+strconv.Itoa(j.NodeID)) + ") | " + j.Workload + " | " +
				length + " | " + fmtUSD(j.GrossCents) + " | " + when + " |\n")
		} else {
			b.WriteString("| " + strconv.Itoa(j.ID) + " | " + j.Workload + " | " + length + " | " + fmtUSD(j.RateCents) + "/h | " +
				fmtUSD(j.GrossCents) + " | " + fmtUSD(j.PoolCents) + " | " + when + " |\n")
		}
	}
	b.WriteString("\n")
	return b.String()
}

func bonusSection(now time.Time) string {
	var b strings.Builder
	b.WriteString("## <gno-icon name=\"coins\" /> Small-node fairness pool\n\n")
	b.WriteString("14% of every job feeds this pool. Anyone can trigger a split (at most once an hour); it is shared **equally** by every node that is online and available at that moment, so a CPU box in a garage gets the same share as a datacenter-class GPU. Inspired by AtomOne's Nakamoto Bonus.\n\n")
	eligible := 0
	nodes.Iterate("", "", func(_ string, v any) bool {
		n := v.(*Node)
		if n.Mode == ModeAvailable && isOnlineAt(n, now) {
			eligible++
		}
		return false
	})
	b.WriteString("- Pool now: **" + fmtUSD(poolCents) + "**, " + strconv.Itoa(eligible) + " nodes eligible")
	if eligible > 0 && poolCents > 0 {
		b.WriteString(" (" + fmtUSD(poolCents/int64(eligible)) + " each)")
	}
	b.WriteString("\n- Rounds so far: " + strconv.Itoa(bonusRounds) + ", " + fmtUSD(poolPaidCents) + " shared\n")
	if !lastDistribution.IsZero() {
		b.WriteString("- Last split: " + ago(now.Sub(lastDistribution)) + "\n")
	}
	b.WriteString("\n<gno-button href=\"" + txlink.NewLink("DistributeBonus").URL() + "\" label=\"Split the pool now\" variant=\"success\" />\n\n")
	return b.String()
}

func registerForm() string {
	if paused {
		return "## Register a node\n\nRegistrations are paused right now.\n\n"
	}
	return "## <gno-icon name=\"plus\" /> Register a node\n\n" +
		"Sign with any gno.land account (testnet). Your node starts *paused*; send a heartbeat and set it to available to take jobs.\n\n" +
		"<gno-frame>\n" +
		"<gno-form exec=\"RegisterNode\">\n" +
		"<gno-input name=\"name\" placeholder=\"Node name, e.g. Garage RTX 4090\" />\n" +
		"<gno-input name=\"kind\" type=\"radio\" value=\"home-gpu\" placeholder=\"Home GPU box\" checked=\"true\" />\n" +
		"<gno-input name=\"kind\" type=\"radio\" value=\"vehicle\" placeholder=\"Vehicle\" />\n" +
		"<gno-input name=\"kind\" type=\"radio\" value=\"cpu\" placeholder=\"CPU-only node\" />\n" +
		"<gno-input name=\"hardware\" placeholder=\"Hardware, e.g. RTX 4090 24GB, Ryzen 9 7950X\" />\n" +
		"<gno-input name=\"region\" placeholder=\"Region, e.g. US-NY Buffalo\" />\n" +
		"<gno-input name=\"power\" type=\"radio\" value=\"grid\" placeholder=\"Grid\" checked=\"true\" />\n" +
		"<gno-input name=\"power\" type=\"radio\" value=\"solar\" placeholder=\"Solar\" />\n" +
		"<gno-input name=\"power\" type=\"radio\" value=\"powershare-backup\" placeholder=\"Powershare backup\" />\n" +
		"<gno-input name=\"rateCents\" type=\"number\" placeholder=\"Rate in US cents per hour, e.g. 45\" />\n" +
		"</gno-form>\n" +
		"</gno-frame>\n\n"
}

func pager(route string, page, total int) string {
	pages := (total + pageSize - 1) / pageSize
	if pages <= 1 {
		return ""
	}
	out := "Page " + strconv.Itoa(page) + " of " + strconv.Itoa(pages)
	if page > 1 {
		out += " · [Previous](" + link(route+"?page="+strconv.Itoa(page-1)) + ")"
	}
	if page < pages {
		out += " · [Next](" + link(route+"?page="+strconv.Itoa(page+1)) + ")"
	}
	return out + "\n"
}

func notFound() string {
	return "# Not found\n\n" + navBar()
}

// ---------------------------------------------------------------------------
// formatting helpers

func link(sub string) string {
	if sub == "" {
		return realmURL
	}
	return realmURL + ":" + sub
}

func pageParam(query string) int {
	for _, kv := range strings.Split(query, "&") {
		if strings.HasPrefix(kv, "page=") {
			p, err := strconv.Atoi(strings.TrimPrefix(kv, "page="))
			if err == nil && p >= 1 && p <= 100000 {
				return p
			}
		}
	}
	return 1
}

func statusOf(n *Node, now time.Time) string {
	if n.Mode == ModeDriving {
		return "Driving"
	}
	if !isOnlineAt(n, now) {
		return "Offline"
	}
	if n.Mode == ModePaused {
		return "Online, paused"
	}
	if n.Kind == KindVehicle {
		return "Parked & plugged in"
	}
	return "Online, available"
}

func rankOf(n *Node) int {
	rank := 1
	key := rankKey(n.TotalCents(), n.ID)
	leaderboard.Iterate("", key, func(_ string, _ any) bool {
		rank++
		return false
	})
	return rank
}

func kindLabel(kind string) string {
	switch kind {
	case KindHomeGPU:
		return "Home GPU"
	case KindVehicle:
		return "Vehicle"
	case KindCPU:
		return "CPU"
	}
	return kind
}

func kindIcon(kind string) string {
	switch kind {
	case KindVehicle:
		return "<gno-icon name=\"battery-charging\" />"
	case KindCPU:
		return "<gno-icon name=\"server\" />"
	}
	return "<gno-icon name=\"lightning\" />"
}

func powerLabel(p string) string {
	switch p {
	case PowerGrid:
		return "Grid power"
	case PowerSolar:
		return "Solar"
	case PowerPowershare:
		return "Powershare backup"
	}
	return p
}

func medal(rank int) string {
	switch rank {
	case 1:
		return "🥇"
	case 2:
		return "🥈"
	case 3:
		return "🥉"
	}
	return strconv.Itoa(rank)
}

func boolWord(b bool, yes, no string) string {
	if b {
		return yes
	}
	return no
}

// fmtUSD renders cents as $1,234.56.
func fmtUSD(cents int64) string {
	neg := cents < 0
	if neg {
		cents = -cents
	}
	whole := strconv.FormatInt(cents/100, 10)
	frac := strconv.FormatInt(cents%100, 10)
	if len(frac) < 2 {
		frac = "0" + frac
	}
	for i := len(whole) - 3; i > 0; i -= 3 {
		whole = whole[:i] + "," + whole[i:]
	}
	out := "$" + whole + "." + frac
	if neg {
		out = "-" + out
	}
	return out
}

func fmtDuration(d time.Duration) string {
	if d < time.Minute {
		return strconv.Itoa(int(d/time.Second)) + "s"
	}
	mins := int(d / time.Minute)
	if mins < 60 {
		return strconv.Itoa(mins) + "m"
	}
	h, m := mins/60, mins%60
	if h < 48 {
		if m == 0 {
			return strconv.Itoa(h) + "h"
		}
		return strconv.Itoa(h) + "h " + strconv.Itoa(m) + "m"
	}
	return strconv.Itoa(h/24) + "d " + strconv.Itoa(h%24) + "h"
}

func ago(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	return fmtDuration(d) + " ago"
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// safeAddrText echoes a user-supplied path segment only if it looks like an
// address, so the page never reflects arbitrary markdown.
func safeAddrText(s string) string {
	if address(s).IsValid() {
		return shortAddr(address(s))
	}
	return "(invalid address)"
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return strconv.Itoa(n) + " " + word + "s"
}
