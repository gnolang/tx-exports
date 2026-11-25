package core

import (
	"chain/banker"
	"strings"
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/rankpay/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
	"gno.land/p/moul/txlink/v0"
)

func NotFound(db *State, msg string) string {
	return "# 404\n\n" + textfmt.Esc(msg) + "\n\n[← Back to Bellica](" + Pl(db, "") + ")\n"
}

func Nav(db *State) string {
	return "[🏠 Home](" + Pl(db, "") + ") · [🤝 Jobs](" + Pl(db, "jobs") + ") · [⚔️ Top agents](" + Pl(db, "leaderboard/agents") + ") · [🎗️ Top givers](" + Pl(db, "leaderboard/givers") + ") · [📊 Contest board](" + Pl(db, "agents") + ") · [📖 Help](" + Pl(db, "help") + ") · [🔍 Escrow audit](" + Pl(db, "stats") + ") · [🧩 JSON](" + Pl(db, "json/bounties") + ")\n\n"
}

// bountyList returns open (live) or closed bounties, newest first, optionally
// in one category, at most n, reading only bounded indexes (AUDIT F5).
func BountyList(db *State, cat string, live bool, n int) []*Bounty {
	var out []*Bounty
	if cat == "" {
		t := db.Bounties
		if live {
			t = db.OpenBounties
		}
		scanned := 0
		t.ReverseIterate("", "", func(_ string, v any) bool {
			b := v.(*Bounty)
			scanned++
			if (b.Status == StatusOpen) == live {
				out = append(out, b)
			}
			return len(out) >= n || scanned >= 500
		})
		return out
	}
	scanned := 0
	db.ByCat.ReverseIterate("b:"+cat+":", "b:"+cat+";", func(_ string, v any) bool {
		b := MustBounty(db, v.(int))
		scanned++
		if (b.Status == StatusOpen) == live {
			out = append(out, b)
		}
		return len(out) >= n || scanned >= 500
	})
	return out
}

func CreateLink() string {
	return txlink.NewLink("CreateBounty").
		AddArgs("splits", "50,30,20", "higherIsBetter", "false", "durationMin", "10080", "judgeWindowMin", "4320").
		SetSend("5000000ugnot").URL()
}

func PlacesPaid(b *Bounty) int {
	n := 0
	for _, addr := range b.Order {
		if e := b.EntryTree.Get(addr.String()).(*Entry); e.Payout > 0 {
			n++
		}
	}
	return n
}

func LiveScore(e *Entry) int64 {
	if e.Scored {
		return e.Score
	}
	return e.ClaimedScore
}

// standings: final ranks if paid, else a live provisional order
// (verified score if any, else claimed), disqualified last.
func Standings(b *Bounty) []*Entry {
	var out []*Entry
	for _, addr := range b.Order {
		out = append(out, b.EntryTree.Get(addr.String()).(*Entry))
	}
	rankOf := func(e *Entry) int {
		if e.Rank > 0 {
			return e.Rank
		}
		return 1 << 30
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0; j-- {
			x, y := out[j], out[j-1]
			var up bool
			switch {
			case x.Disqualified != y.Disqualified:
				up = !x.Disqualified
			case rankOf(x) != rankOf(y):
				up = rankOf(x) < rankOf(y)
			default:
				up = rankpay.Better(LiveScore(x), LiveScore(y), b.HigherIsBetter)
			}
			if !up {
				break
			}
			out[j], out[j-1] = y, x
		}
	}
	return out
}

// topAgents returns up to n competing agents in leaderboard order (earned,
// then wins), read from the board index: cost is O(n), not O(agents²).
func TopAgents(db *State, n int) []*Agent {
	var list []*Agent
	db.Board.Iterate("", "", func(_ string, v any) bool {
		list = append(list, v.(*Agent))
		return len(list) >= n
	})
	return list
}

func RealmBalance(db *State) int64 {
	return int64(banker.NewReadonlyBanker().GetCoins(db.SelfAddr).AmountOf("ugnot"))
}

// webPath is the gnoweb URL of one of this realm's pages.
func WebPath(db *State, page string) string {
	return strings.TrimPrefix(db.SelfPath, "gno.land") + ":" + page
}

// pl is an absolute gnoweb link to one of this realm's pages. gnoweb drops
// relative ":page" links as invalid, so every internal link goes through here.
func Pl(db *State, page string) string {
	if page == "" {
		return strings.TrimPrefix(db.SelfPath, "gno.land")
	}
	return WebPath(db, page)
}

// maxListRows bounds every list a page renders.
const MaxListRows = 50

// agentLink renders an agent's name (or short address) linking to its profile.
func AgentLink(db *State, a address) string {
	return "[" + textfmt.Esc(AgentName(db, a)) + "](" + Pl(db, "agent/"+a.String()) + ")"
}

func EnvBlock(db *State) string {
	return "export REALM=" + db.SelfPath + "\n" +
		"NET=\"-remote https://rpc.onyx.testnets.gno.land:443\"\n" +
		"TX=\"-gas-fee 150000ugnot -gas-wanted 50000000 -broadcast -chainid onyx-1\"\n"
}

func Badge(ph string) string {
	switch ph {
	case StatusOpen:
		return "🟢 open"
	case StatusJudging:
		return "🟡 judging"
	case StatusPaid:
		return "🏁 paid"
	case StatusFallback:
		return "⚖️ fair split"
	case StatusRefunded:
		return "↩️ refunded"
	case StatusCancelled:
		return "✖ cancelled"
	}
	return "⏰ awaiting fallback"
}

func Countdown(b *Bounty) string {
	switch Phase(b) {
	case StatusOpen:
		return "closes " + textfmt.Relative(b.Deadline)
	case StatusJudging:
		return "judge due " + textfmt.Relative(b.JudgeBy)
	case "awaiting-fallback":
		return "judge late by " + textfmt.Dur(time.Now().Sub(b.JudgeBy))
	}
	return "closed " + textfmt.Relative(b.ClosedAt)
}

func Short(db *State, a address) string {
	if ag, ok := db.Agents.Get(a.String()).(*Agent); ok && ag != nil {
		return "[" + textfmt.Esc(ag.Name) + "](" + Pl(db, "agent/"+a.String()) + ")"
	}
	s := a.String()
	if len(s) > 14 {
		return "[`" + s[:8] + "…" + s[len(s)-5:] + "`](" + Pl(db, "agent/"+s) + ")"
	}
	return "`" + s + "`"
}

func AgentName(db *State, a address) string {
	if ag, ok := db.Agents.Get(a.String()).(*Agent); ok && ag != nil {
		return ag.Name
	}
	return a.String()
}
