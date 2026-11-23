package hearthboard

import (
	"chain/runtime"
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xj5r20d9yy4hfap0x5w3p9nu4x27mekc8pscgs/ember"
)

const (
	boardPath = "gno.land/r/g1xj5r20d9yy4hfap0x5w3p9nu4x27mekc8pscgs/hearthboard"
	emberPath = "gno.land/r/g1xj5r20d9yy4hfap0x5w3p9nu4x27mekc8pscgs/ember"
)

func Render(path string) string {
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "account" && validAccount(parts[1]) {
		owner := address(parts[1])
		return ufmt.Sprintf(`{"balance":"%d","starterClaimed":%t}`, ember.BalanceOf(owner), ember.ClaimedStarter(owner))
	}
	if len(parts) == 2 && (parts[0] == "page" || parts[0] == "quest" || parts[0] == "api") {
		n, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || n < 0 {
			return "No such board page."
		}
		switch parts[0] {
		case "page":
			return renderBoard(n)
		case "quest":
			if q := getQuest(n); q != nil {
				return renderQuest(q)
			}
		case "api":
			return renderAPI(n)
		}
	}
	if path == "" {
		return renderBoard(0)
	}
	if path == "leaderboard" {
		return renderLeaderboard()
	}
	return "No such board page."
}

func renderBoard(before int64) string {
	var out strings.Builder
	out.WriteString("# Hearthboard\n\n*The tavern quest board · On-chain quests, bounties and tips.*\n\n")
	out.WriteString(ufmt.Sprintf("**%d** posted · **%d** completed · **%d EMBER** in escrow\n\n", latest, fulfilled, escrowed))
	out.WriteString(ufmt.Sprintf("[Leaderboard](%s:leaderboard) · [EMBER token](%s) · [Web UI source](https://github.com/ZQ051031/gnome-tavern-hackathon/tree/main/web)\n\n",
		readPath(boardPath), readPath(emberPath)))
	out.WriteString("## Quest ledger\n\n")
	next := eachPage(before, func(q *Quest) {
		out.WriteString(ufmt.Sprintf("- [#%d · %s](%s:quest/%d) — **%s** · %d EMBER bounty · %d tipped\n",
			q.ID, sanitize.InlineText(q.Title), readPath(boardPath), q.ID, displayState(q), q.Bounty, q.Tips))
	})
	if latest == 0 {
		out.WriteString("The board is empty. Post the first quest from the web UI or CLI.\n")
	}
	if next != 0 {
		out.WriteString(ufmt.Sprintf("\n[Older quests](%s:page/%d)\n", readPath(boardPath), next))
	}
	if before != 0 {
		out.WriteString(ufmt.Sprintf("\n[Latest quests](%s)\n", readPath(boardPath)))
	}
	return out.String()
}

func renderQuest(q *Quest) string {
	s := ufmt.Sprintf("[← Quest ledger](%s)\n\n# #%d · %s\n\n**%s** · **%d EMBER** bounty · **%d EMBER** tipped\n\n%s\n\n**Poster:** `%s`\n",
		readPath(boardPath), q.ID, sanitize.InlineText(q.Title), displayState(q), q.Bounty, q.Tips, sanitize.InlineText(q.Brief), q.Poster.String())
	if q.Solver != "" {
		s += ufmt.Sprintf("\n**Solver:** `%s`\n", q.Solver.String())
	}
	if active(q) {
		s += ufmt.Sprintf("\n**Claim expires at block:** %d\n", q.Deadline)
	}
	if q.Proof != "" {
		s += "\n## Submitted proof\n\n" + sanitize.InlineText(q.Proof) + "\n"
	}
	return s
}

func renderLeaderboard() string {
	out := ufmt.Sprintf("[← Quest ledger](%s)\n\n# Hall of Embers\n\nRanked by poster-approved quests; tips do not affect rank.\n\n", readPath(boardPath))
	if len(leaders) == 0 {
		return out + "No completed quests yet.\n"
	}
	for _, row := range leaders {
		out += ufmt.Sprintf("1. `%s` — **%d** completed\n", row.Solver.String(), row.Solved)
	}
	return out
}

func renderAPI(before int64) string {
	var out strings.Builder
	out.WriteString(ufmt.Sprintf(`{"height":"%d","latest":"%d","completed":"%d","escrowed":"%d","escrow":"%s","quests":[`,
		runtime.ChainHeight(), latest, fulfilled, escrowed, EscrowAddress().String()))
	first := true
	next := eachPage(before, func(q *Quest) {
		if !first {
			out.WriteString(",")
		}
		first = false
		out.WriteString(ufmt.Sprintf(`{"id":"%d","title":"%s","brief":"%s","poster":"%s","solver":"%s","proof":"%s","bounty":"%d","tips":"%d","state":"%s","expired":%t,"deadline":"%d"}`,
			q.ID, encoded(q.Title), encoded(q.Brief), q.Poster.String(), q.Solver.String(), encoded(q.Proof), q.Bounty, q.Tips, q.State, expired(q), q.Deadline))
	})
	out.WriteString(ufmt.Sprintf(`],"next":"%d","leaders":[`, next))
	for i, row := range leaders {
		if i > 0 {
			out.WriteString(",")
		}
		out.WriteString(ufmt.Sprintf(`{"solver":"%s","solved":"%d"}`, row.Solver.String(), row.Solved))
	}
	out.WriteString("]}")
	return out.String()
}

func eachPage(before int64, visit func(*Quest)) int64 {
	id := latest
	if before > 0 && before <= latest {
		id = before - 1
	}
	for n := 0; id > 0 && n < pageSize; n++ {
		visit(mustQuest(id))
		id--
	}
	if id > 0 {
		return id + 1
	}
	return 0
}

func displayState(q *Quest) string {
	if expired(q) {
		return q.State + " · lease expired"
	}
	return q.State
}

func readPath(path string) string { return strings.TrimPrefix(path, "gno.land") }
func encoded(s string) string     { return base64.StdEncoding.EncodeToString([]byte(s)) }

func validAccount(s string) bool {
	if len(s) != 40 || !strings.HasPrefix(s, "g1") {
		return false
	}
	for _, c := range s[2:] {
		if !strings.ContainsRune("qpzry9x8gf2tvdw0s3jn54khce6mua7l", c) {
			return false
		}
	}
	return true
}
