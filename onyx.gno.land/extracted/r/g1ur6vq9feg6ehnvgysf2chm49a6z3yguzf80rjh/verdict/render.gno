package verdict

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/md/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/ufmt/v0"
	pm "gno.land/p/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/parimutuel"
)

const pageSize = 20

type posRow struct {
	who string
	pos pm.Position
}

type lbEntry struct {
	who string
	s   *Stats
}

// Render serves the gnoweb UI:
//
//	""             home: open markets, recently resolved, stats
//	"m/<id>"       a market page with odds and one-click bet buttons
//	"leaderboard"  top forecasters by profit
//	"u/<address>"  someone's positions
//	"new"          how to open a market
func Render(path string) string {
	path = strings.Trim(path, "/")
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "m/"):
		id, err := strconv.Atoi(strings.TrimPrefix(path, "m/"))
		if err != nil {
			return "# Not found\n\nBad market id."
		}
		return renderMarket(id)
	case path == "leaderboard":
		return renderLeaderboard()
	case strings.HasPrefix(path, "u/"):
		return renderUser(address(strings.TrimPrefix(path, "u/")))
	case path == "new":
		return renderNew()
	}
	return "# Not found\n\n[Back home](" + realmLink("") + ")"
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# Verdict\n\n")
	sb.WriteString("**Put your GNOT where your opinion is.** Bet on GovDAO votes and community questions. ")
	sb.WriteString("GovDAO markets settle straight from on-chain governance, with no oracle and no admin.\n\n")

	sb.WriteString(ufmt.Sprintf("%s markets · %s GNOT wagered · [Leaderboard](%s) · [Open a market](%s)\n\n",
		strconv.Itoa(MarketCount()), fmtGNOT(totalVolume), realmLink("leaderboard"), realmLink("new")))

	open, resolved := []*Market{}, []*Market{}
	markets.ReverseIterate("", "", func(_ string, v any) bool {
		m := v.(*Market)
		if m.Pool.Outcome() == pm.Pending {
			if len(open) < pageSize {
				open = append(open, m)
			}
		} else if len(resolved) < 10 {
			resolved = append(resolved, m)
		}
		return len(open) >= pageSize && len(resolved) >= 10
	})

	sb.WriteString("## Open markets\n\n")
	if len(open) == 0 {
		sb.WriteString("No open markets yet. [Open the first one](" + realmLink("new") + ").\n\n")
	} else {
		sb.WriteString("| Market | YES | Pool | Bettors | Closes |\n|---|---|---|---|---|\n")
		for _, m := range open {
			sb.WriteString(ufmt.Sprintf("| [%s](%s) | %s | %s GNOT | %d | %s |\n",
				md.EscapeText(m.Question), realmLink("m/"+strconv.Itoa(m.ID)),
				fmtPct(m.Pool.YesBps()), fmtGNOT(m.Pool.Total()), m.Pool.Bettors(), closesLabel(m)))
		}
		sb.WriteString("\n")
	}

	if len(resolved) > 0 {
		sb.WriteString("## Recently resolved\n\n| Market | Result | Pool |\n|---|---|---|\n")
		for _, m := range resolved {
			sb.WriteString(ufmt.Sprintf("| [%s](%s) | **%s** | %s GNOT |\n",
				md.EscapeText(m.Question), realmLink("m/"+strconv.Itoa(m.ID)),
				strings.ToUpper(m.Pool.Outcome().String()), fmtGNOT(m.Pool.Total())))
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## How it works\n\n")
	sb.WriteString("1. Pick a side and stake GNOT (minimum " + fmtGNOT(MinBet) + " GNOT).\n")
	sb.WriteString("2. Everyone on the winning side splits the whole pool, in proportion to their stake.\n")
	sb.WriteString(ufmt.Sprintf("3. A %s fee is taken only when there are winners and losers. If nobody bet on the winning side, or a market is voided, everyone gets a full refund.\n", fmtPct(feeBps)))
	sb.WriteString("4. After the result, press **Claim** on the market page.\n\n")
	sb.WriteString("Payout math lives in a reusable package: [p/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/parimutuel](/p/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/parimutuel).\n")
	return sb.String()
}

func renderMarket(id int) string {
	v := markets.Get(idKey(id))
	if v == nil {
		return "# Market not found\n\n[Back home](" + realmLink("") + ")"
	}
	m := v.(*Market)
	p := m.Pool
	sid := strconv.Itoa(id)

	var sb strings.Builder
	sb.WriteString("# " + md.EscapeText(m.Question) + "\n\n")

	kind := "Community market · resolved by " + shortAddr(m.Creator)
	if m.Kind == KindGovDAO {
		kind = ufmt.Sprintf("GovDAO market · settles automatically from [proposal #%d](/r/gov/dao:%d)", m.ProposalID, m.ProposalID)
	}
	sb.WriteString(kind + "\n\n")

	// odds bar
	yb := p.YesBps()
	filled := int(yb / 500) // 20 cells
	bar := strings.Repeat("🟩", filled) + strings.Repeat("🟥", 20-filled)
	sb.WriteString(bar + "\n\n")
	sb.WriteString(ufmt.Sprintf("**YES %s** · %s GNOT · pays %s  \n", fmtPct(yb), fmtGNOT(p.YesStake()), fmtMult(p.Multiplier(pm.Yes))))
	sb.WriteString(ufmt.Sprintf("**NO %s** · %s GNOT · pays %s\n\n", fmtPct(10_000-yb), fmtGNOT(p.NoStake()), fmtMult(p.Multiplier(pm.No))))
	sb.WriteString(ufmt.Sprintf("Pool: **%s GNOT** from %d bettors · fee %s\n\n", fmtGNOT(p.Total()), p.Bettors(), fmtPct(p.FeeBps())))

	if p.Outcome() == pm.Pending {
		sb.WriteString("## Place a bet\n\n")
		if m.Kind == KindCommunity && !time.Now().Before(m.CloseAt) {
			sb.WriteString("Betting closed " + fmtTime(m.CloseAt) + ". Waiting for the creator to resolve (deadline " + fmtTime(m.ResolveBy) + ").\n\n")
			sb.WriteString(ufmt.Sprintf("Creator: [Resolve YES](%s) · [Resolve NO](%s) · [Void](%s)\n\n",
				txlink.NewLink("Resolve").AddArgs("id", sid, "outcome", "yes").URL(),
				txlink.NewLink("Resolve").AddArgs("id", sid, "outcome", "no").URL(),
				txlink.NewLink("Resolve").AddArgs("id", sid, "outcome", "void").URL()))
		} else {
			sb.WriteString("| | 1 GNOT | 10 GNOT | 100 GNOT |\n|---|---|---|---|\n")
			sb.WriteString("| **YES** | " + betLink(sid, "yes", 1) + " | " + betLink(sid, "yes", 10) + " | " + betLink(sid, "yes", 100) + " |\n")
			sb.WriteString("| **NO** | " + betLink(sid, "no", 1) + " | " + betLink(sid, "no", 10) + " | " + betLink(sid, "no", 100) + " |\n\n")
			sb.WriteString("Any other amount: [custom bet](" + txlink.NewLink("Bet").AddArgs("id", sid).URL() + ") and set the GNOT to send.\n\n")
			if m.Kind == KindCommunity {
				sb.WriteString("Betting closes " + fmtTime(m.CloseAt) + ".\n\n")
			} else {
				sb.WriteString("Betting closes automatically when GovDAO voting ends. Then anyone can [settle the market](" +
					txlink.NewLink("Settle").AddArgs("id", sid).URL() + ").\n\n")
			}
		}
		if !time.Now().Before(m.ResolveBy) {
			sb.WriteString("⚠️ Resolution deadline passed: [void and refund everyone](" + txlink.NewLink("VoidExpired").AddArgs("id", sid).URL() + ").\n\n")
		}
	} else {
		sb.WriteString(ufmt.Sprintf("## Result: %s\n\n", strings.ToUpper(p.Outcome().String())))
		sb.WriteString(md.EscapeText(m.Note) + " · " + fmtTime(m.ResolvedAt) + "\n\n")
		sb.WriteString("[**Claim your payout**](" + txlink.NewLink("Claim").AddArgs("id", sid).URL() + ")\n\n")
	}

	// positions
	rows := []posRow{}
	p.IterPositions(func(who string, pos pm.Position) bool {
		rows = append(rows, posRow{who, pos})
		return false
	})
	if len(rows) > 0 {
		sb.WriteString("## Positions\n\n| Bettor | YES | NO | Claimed |\n|---|---|---|---|\n")
		for i, r := range rows {
			if i >= 50 {
				sb.WriteString(ufmt.Sprintf("\n…and %d more\n", len(rows)-50))
				break
			}
			claimed := ""
			if r.pos.Claimed {
				claimed = "✅"
			}
			sb.WriteString(ufmt.Sprintf("| [%s](%s) | %s | %s | %s |\n",
				shortAddr(address(r.who)), realmLink("u/"+r.who), fmtGNOT(r.pos.Yes), fmtGNOT(r.pos.No), claimed))
		}
		sb.WriteString("\n")
	}

	sb.WriteString("---\n\nShare: `" + "gno.land/r/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/verdict:m/" + sid + "` · [All markets](" + realmLink("") + ")\n")
	return sb.String()
}

func renderLeaderboard() string {
	list := []lbEntry{}
	stats.Iterate("", "", func(k string, v any) bool {
		list = append(list, lbEntry{k, v.(*Stats)})
		return false
	})
	// insertion sort by profit, descending
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j].s.Profit() > list[j-1].s.Profit(); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}

	var sb strings.Builder
	sb.WriteString("# Leaderboard\n\nTop forecasters by realized profit (claimed winnings minus GNOT wagered).\n\n")
	if len(list) == 0 {
		sb.WriteString("No bets yet.\n")
		return sb.String()
	}
	sb.WriteString("| # | Forecaster | Profit | Wagered | Bets | Wins |\n|---|---|---|---|---|---|\n")
	for i, e := range list {
		if i >= 50 {
			break
		}
		sb.WriteString(ufmt.Sprintf("| %d | [%s](%s) | %s | %s | %d | %d |\n",
			i+1, shortAddr(address(e.who)), realmLink("u/"+e.who), fmtSigned(e.s.Profit()), fmtGNOT(e.s.Wagered), e.s.Bets, e.s.Wins))
	}
	sb.WriteString("\n[Back to markets](" + realmLink("") + ")\n")
	return sb.String()
}

func renderUser(addr address) string {
	var sb strings.Builder
	sb.WriteString("# Forecaster " + shortAddr(addr) + "\n\n")
	if v := stats.Get(addr.String()); v != nil {
		s := v.(*Stats)
		sb.WriteString(ufmt.Sprintf("Profit %s · wagered %s GNOT · %d bets · %d wins\n\n", fmtSigned(s.Profit()), fmtGNOT(s.Wagered), s.Bets, s.Wins))
	}
	sb.WriteString("| Market | YES | NO | Status | Claimable |\n|---|---|---|---|---|\n")
	found := false
	markets.ReverseIterate("", "", func(_ string, v any) bool {
		m := v.(*Market)
		pos := m.Pool.Position(addr)
		if pos.Total() == 0 {
			return false
		}
		found = true
		claim := ""
		if pay := m.Pool.Payout(addr); pay > 0 && m.Pool.Outcome() != pm.Pending {
			claim = "[" + fmtGNOT(pay) + " GNOT](" + txlink.NewLink("Claim").AddArgs("id", strconv.Itoa(m.ID)).URL() + ")"
		}
		sb.WriteString(ufmt.Sprintf("| [%s](%s) | %s | %s | %s | %s |\n",
			md.EscapeText(clamp(m.Question, 80)), realmLink("m/"+strconv.Itoa(m.ID)),
			fmtGNOT(pos.Yes), fmtGNOT(pos.No), m.Pool.Outcome().String(), claim))
		return false
	})
	if !found {
		sb.WriteString("| no positions yet | | | | |\n")
	}
	return sb.String()
}

func renderNew() string {
	var sb strings.Builder
	sb.WriteString("# Open a market\n\n")
	sb.WriteString("## On a GovDAO proposal\n\nPick an [open proposal](/r/gov/dao) and enter its number. ")
	sb.WriteString("The market settles itself from the vote, so it's the most trustworthy kind.\n\n")
	sb.WriteString("[Create GovDAO market](" + txlink.NewLink("CreateGovDAOMarket").URL() + ")\n\n")
	sb.WriteString("## Community question\n\nAny yes/no question with a clear answer, for example *\"Will GNOT close above $0.10 on Dec 31?\"*. ")
	sb.WriteString("You set when betting closes (in hours). You resolve it afterwards and cannot bet on it yourself. ")
	sb.WriteString("If you don't resolve within 7 days, anyone can void it and refund every bettor.\n\n")
	sb.WriteString("[Create community market](" + txlink.NewLink("CreateMarket").URL() + ")\n")
	return sb.String()
}

// ---------------------------------------------------------------------------
// formatting

func betLink(id, side string, gnot int64) string {
	return "[" + strings.ToUpper(side) + " " + strconv.FormatInt(gnot, 10) + "](" +
		txlink.NewLink("Bet").AddArgs("id", id, "side", side).SetSend(strconv.FormatInt(gnot*1_000_000, 10)+"ugnot").URL() + ")"
}

func realmLink(sub string) string {
	if sub == "" {
		return "/r/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/verdict"
	}
	return "/r/g1ur6vq9feg6ehnvgysf2chm49a6z3yguzf80rjh/verdict:" + sub
}

// fmtGNOT formats ugnot as GNOT with two decimals.
func fmtGNOT(u int64) string {
	neg := u < 0
	if neg {
		u = -u
	}
	s := strconv.FormatInt(u/1_000_000, 10) + "." + pad2((u%1_000_000)/10_000)
	if neg {
		return "-" + s
	}
	return s
}

func fmtSigned(u int64) string {
	if u > 0 {
		return "+" + fmtGNOT(u)
	}
	return fmtGNOT(u)
}

func fmtPct(bps int64) string {
	return strconv.FormatInt(bps/100, 10) + "." + strconv.FormatInt((bps%100)/10, 10) + "%"
}

func fmtMult(bps int64) string {
	if bps == 0 {
		return "—"
	}
	return strconv.FormatInt(bps/10_000, 10) + "." + pad2((bps%10_000)/100) + "x"
}

func pad2(n int64) string {
	if n < 10 {
		return "0" + strconv.FormatInt(n, 10)
	}
	return strconv.FormatInt(n, 10)
}

func fmtTime(t time.Time) string {
	return t.UTC().Format("Jan 2, 15:04 UTC")
}

func closesLabel(m *Market) string {
	if m.Kind == KindGovDAO {
		return "when vote ends"
	}
	if !time.Now().Before(m.CloseAt) {
		return "closed"
	}
	return fmtTime(m.CloseAt)
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}
