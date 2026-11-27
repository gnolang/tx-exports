package aegis_pit

import (
	"strconv"
	"strings"

	core "gno.land/p/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_core"
)

// Render serves 5 gnoweb screens:
//
//	""            arena lobby
//	"match/<id>"  duel board + combat log
//	"fighters"    leaderboard, trust, backer tokens, badges
//	"lab"         breaker lab: blocked attacks, slashes, preflight reports
//	"exit"        emergency exit (plain text + direct withdraw links)
func Render(path string) string {
	switch {
	case path == "":
		return renderLobby()
	case strings.HasPrefix(path, "match/"):
		id, err := strconv.Atoi(strings.TrimPrefix(path, "match/"))
		if err != nil || matches.Get(key(id)) == nil {
			return "# 404\nMatch not found. [Back to lobby](" + linkPath() + ")"
		}
		return renderMatch(getMatch(id))
	case path == "fighters":
		return renderFighters()
	case path == "lab":
		return renderLab()
	case path == "exit":
		return renderExit()
	}
	return "# 404\n[Back to lobby](" + linkPath() + ")"
}

func nav() string {
	p := linkPath()
	return "[Arena](" + p + ") · [Fighters](" + p + ":fighters) · [Breaker Lab](" + p + ":lab) · [Emergency Exit](" + p + ":exit)\n\n"
}

func renderLobby() string {
	out := "# ⚔️ Aegis Pit\n" + nav()
	out += "Oracle-free prediction market on deterministic AI duels. Commit-reveal locks moves **and** bets at the same block; no-shows lose their bond.\n\n"
	out += "**Block:** " + strconv.FormatInt(height(), 10) + " · **Season fund:** " + strconv.FormatInt(seasonFund, 10) + " ugnot · "
	out += "[Register fighter](" + txLink("RegisterFighter") + ") · [Create match](" + txLink("CreateMatch") + ") · [Claim winnings](" + txLink("Claim") + ")\n\n"
	if matches.Size() == 0 {
		return out + "_No matches yet. Register a fighter and open one._\n"
	}
	out += "## Matches\n\n"
	count := 0
	matches.ReverseIterate("", "", func(k string, v any) bool {
		m := v.(*Match)
		out += "[" + matchCardSVG(m) + "](" + linkPath() + ":match/" + itoa(m.ID) + ")\n\n"
		count++
		return count >= 10
	})
	return out
}

func renderMatch(m *Match) string {
	id := itoa(m.ID)
	fa := getFighter(m.A)
	out := "# Match #" + id + "\n" + nav() + matchCardSVG(m) + "\n\n"
	out += "| | " + fa.Name + " (A)"
	nameB := "—"
	if m.B != 0 {
		nameB = getFighter(m.B).Name
	}
	out += " | " + nameB + " (B) |\n|---|---|---|\n"
	out += "| Commit | " + yesNo(m.CommitA != "") + " | " + yesNo(m.CommitB != "") + " |\n"
	out += "| Reveal | " + orDash(m.MovesA) + " | " + orDash(m.MovesB) + " |\n"
	out += "| Pool (ugnot) | " + strconv.FormatInt(m.PoolA, 10) + " | " + strconv.FormatInt(m.PoolB, 10) + " |\n\n"
	out += "**Mode:** " + modeLabel(m) + " · **Bond:** " + strconv.FormatInt(m.Bond, 10) + " ugnot · **Phase:** " + phase(m) + "\n\n"

	switch m.Status {
	case StatusOpen:
		out += "[Join this match](" + txLink("JoinMatch", "matchID", id) + ") (attach exactly the bond)\n"
	case StatusLive:
		if height() <= m.CommitDeadline {
			out += "[Commit move](" + txLink("CommitMove", "matchID", id) + ")"
			if m.Ranked {
				out += " · [Bet on A](" + txLink("PlaceBet", "matchID", id, "side", "1") + ") · [Bet on B](" + txLink("PlaceBet", "matchID", id, "side", "2") + ")"
			}
			out += "\n"
		} else if height() <= m.RevealDeadline {
			out += "[Reveal](" + txLink("Reveal", "matchID", id) + ")\n"
		} else {
			out += "[Slash no-show](" + txLink("SlashNoReveal", "matchID", id) + ")\n"
		}
	}
	if len(m.Log) > 0 {
		out += "\n## Combat log\n\n| Round | A | B | HP A | HP B |\n|---|---|---|---|---|\n"
		for i, r := range m.Log {
			out += "| " + itoa(i+1) + " | " + core.MoveName(r.MoveA) + " | " + core.MoveName(r.MoveB) + " | " + itoa(r.HPA) + " | " + itoa(r.HPB) + " |\n"
		}
	}
	if m.Note != "" {
		out += "\n> " + m.Note + "\n"
	}
	return out
}

func renderFighters() string {
	out := "# 🏆 Fighters\n" + nav()
	if fighters.Size() == 0 {
		return out + "_No fighters yet._ [Register one](" + txLink("RegisterFighter") + ")\n"
	}
	out += "| # | Fighter | W / L / D | Forfeits | Trust (owner) | Backer token | Supply | Paid to backers | Source |\n|---|---|---|---|---|---|---|---|---|\n"
	badges := ""
	fighters.Iterate("", "", func(k string, v any) bool {
		f := v.(*Fighter)
		out += "| " + itoa(f.ID) + " | **" + escapeMd(f.Name) + "** | " + itoa(f.Wins) + " / " + itoa(f.Losses) + " / " + itoa(f.Draws) +
			" | " + itoa(f.Forfeits) + " | " + strconv.FormatInt(TrustScore(f.Owner), 10) +
			" | " + f.Backers.Symbol + " | " + strconv.FormatInt(f.Backers.Supply, 10) +
			" | " + strconv.FormatInt(f.Backers.Distributed, 10) + " ugnot | `" + orDash(f.PkgPath) + "` |\n"
		if len(f.Badges) > 0 {
			badges += "**" + escapeMd(f.Name) + "** "
			for _, b := range f.Badges {
				badges += badgeSVG(b) + " "
			}
			badges += "\n\n"
		}
		return false
	})
	if badges != "" {
		out += "\n## Badges\n\n" + badges
	}
	out += "\nTrust only moves on **ranked** matches with real ugnot at stake. Other realms can read it via `TrustScore(addr)`.\n"
	return out
}

func renderLab() string {
	out := "# 🧪 Breaker Lab\n" + nav()
	out += "Prompt-injection attempts, slashed no-shows and pre-flight reports. Every blocked line is a spend the AI tried that the on-chain policy refused.\n\n"
	if len(lab) == 0 {
		return out + "_No events yet._\n"
	}
	out += "| Block | Kind | Detail |\n|---|---|---|\n"
	for i := len(lab) - 1; i >= 0; i-- {
		e := lab[i]
		out += "| " + strconv.FormatInt(e.Height, 10) + " | " + kindIcon(e.Kind) + " | " + escapeMd(e.Detail) + " |\n"
	}
	return out
}

func renderExit() string {
	out := "# Emergency Exit\n\n"
	out += "This page is plain text on purpose: it works even if every external website is down.\n\n"
	out += "1. Withdraw a whole budget box: [EmergencyWithdraw](" + txLink("EmergencyWithdraw") + ") (owner only)\n"
	out += "2. Withdraw winnings, refunds, bonds and backer dividends: [Claim](" + txLink("Claim") + ")\n\n"
	out += "CLI:\n\n```\ngnokey maketx call -pkgpath " + selfPath + " -func EmergencyWithdraw -args <boxID> \\\n  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid onyx-1 \\\n  -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n```\n\n"
	open := ""
	boxes.Iterate("", "", func(k string, v any) bool {
		b := v.(*Box)
		if !b.Closed && b.Balance > 0 {
			open += "- Box #" + itoa(b.ID) + " · owner " + string(b.Owner) + " · " + strconv.FormatInt(b.Balance, 10) +
				" ugnot · [withdraw](" + txLink("EmergencyWithdraw", "boxID", itoa(b.ID)) + ")\n"
		}
		return false
	})
	if open != "" {
		out += "Open boxes:\n\n" + open
	}
	return out
}

func yesNo(b bool) string {
	if b {
		return "✅"
	}
	return "⏳"
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

func kindIcon(k string) string {
	switch k {
	case "blocked":
		return "🛡️ blocked"
	case "slash":
		return "🔪 slash"
	case "preflight":
		return "🔍 preflight"
	case "exit":
		return "🚪 exit"
	}
	return k
}

func escapeMd(s string) string {
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\n", " ")
	return s
}
