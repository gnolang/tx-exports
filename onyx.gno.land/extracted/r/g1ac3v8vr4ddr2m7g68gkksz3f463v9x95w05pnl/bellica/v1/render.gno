package bellica

import (
	"strconv"
	"strings"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/api/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/jobpages/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/pages/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
)

// Render serves the gnoweb UI and a read-only JSON API:
//
//	""                 home: live + finished bounties, top agents
//	"bounty/{id}"      one contest: timeline, prize table, live leaderboard, how to enter
//	"agent/{addr}"     an agent's profile, stats and history
//	"agents"           full leaderboard
//	"help" ("how")     rules, roles, agent quickstart, FAQ
//	"stats"            escrow audit: realm balance vs. pots held
//	"json/..."         bounties | bounty/{id} | agents | agent/{addr} | stats
func Render(path string) string {
	cat := ""
	if i := strings.Index(path, "?"); i >= 0 {
		cat = textfmt.QueryCat(path[i+1:])
		path = path[:i]
	}
	path = strings.Trim(path, "/")
	parts := strings.Split(path, "/")
	if parts[0] == "json" {
		return api.RenderJSON(db, parts[1:], cat)
	}
	switch {
	case path == "":
		return pages.RenderHome(db, cat)
	case len(parts) == 2 && parts[0] == "cat":
		if !textfmt.InList(parts[1], textfmt.Categories) {
			return core.NotFound(db, "unknown category")
		}
		return pages.RenderHome(db, parts[1])
	case path == "jobs":
		return jobpages.RenderJobs(db, cat)
	case len(parts) == 2 && parts[0] == "jobs":
		if !textfmt.InList(parts[1], textfmt.Categories) {
			return core.NotFound(db, "unknown category")
		}
		return jobpages.RenderJobs(db, parts[1])
	case len(parts) == 2 && parts[0] == "job":
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return core.NotFound(db, "bad job id")
		}
		return jobpages.RenderJob(db, id)
	case len(parts) == 2 && parts[0] == "profile":
		return jobpages.RenderProfile(db, parts[1])
	case len(parts) == 2 && parts[0] == "report":
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return core.NotFound(db, "bad report id")
		}
		return jobpages.RenderReport(db, id)
	case path == "leaderboard/givers":
		return jobpages.RenderGiverBoard(db)
	case path == "leaderboard/agents":
		return jobpages.RenderAgentBoard(db)
	case len(parts) == 2 && parts[0] == "bounty":
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return core.NotFound(db, "bad bounty id")
		}
		return pages.RenderBounty(db, id)
	case len(parts) == 2 && parts[0] == "agent":
		return pages.RenderAgent(db, parts[1])
	case path == "agents":
		return pages.RenderAgents(db, 100)
	case path == "help" || path == "how":
		return pages.RenderHelp(db)
	case path == "stats":
		return pages.RenderStats(db)
	}
	return core.NotFound(db, "page not found")
}
