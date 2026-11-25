package tavernwagers

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Render shows the realm's pages on gnoweb:
//
//	""         home: how it works + all tables
//	"table/N"  a table: members, leaderboard, bets
//	"bet/N"    a bet: players, reports, votes, payouts, actions
func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 2 {
		if _, err := strconv.Atoi(parts[1]); err == nil {
			switch parts[0] {
			case "table":
				if v := tables.Get(parts[1]); v != nil {
					return renderTable(v.(*Table))
				}
				return "# Table not found\n\n[Back home](" + home() + ")"
			case "bet":
				if v := bets.Get(parts[1]); v != nil {
					return renderBet(v.(*Bet))
				}
				return "# Bet not found\n\n[Back home](" + home() + ")"
			}
		}
	}
	return renderHome()
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# 🍺 Tavern Wagers\n\n")
	sb.WriteString("**Bet on anything with your friends. The money's locked upfront, neutral judges call it, and the winner gets paid automatically. No more \"I'll pay you later.\"**\n\n")
	sb.WriteString("## How it works\n\n")
	sb.WriteString("1. **Open a table** and invite your friends.\n")
	sb.WriteString("2. **Make a bet** against a friend. Both players lock the same stake + a 10% honesty bond.\n")
	sb.WriteString("3. **Play** (chess, FIFA, D&D, anything).\n")
	sb.WriteString("4. **Both players report the result.** If you agree, you're paid instantly and get your bonds back.\n")
	sb.WriteString("5. **Disagree?** Everyone else at the table becomes a judge. They have no money in it, so they have no reason to lie. A strict majority decides.\n")
	sb.WriteString("6. **Lying costs you.** The player who loses the vote forfeits their bond: half to the honest player, half to the judges. Judges also split a 1% fee for showing up.\n")
	sb.WriteString("7. **No majority before the deadline?** Everyone is refunded in full.\n\n")
	sb.WriteString("The realm keeps nothing. Every coin that goes in comes back out to players and judges.\n\n")
	sb.WriteString("[➕ Open a new table](" + call("CreateTable") + ")\n\n")

	sb.WriteString(count(tables.Size(), "table") + " · " + count(bets.Size(), "bet") + " · " +
		count(totalSettled, "settled bet") + " · **" + gnot(totalLocked, false) + "** locked all time\n\n")

	sb.WriteString("## Tables\n\n")
	if tables.Size() == 0 {
		sb.WriteString("_No tables yet. Be the first._\n")
		return sb.String()
	}
	sb.WriteString("| Table | Members | Bets | Owner |\n|---|---|---|---|\n")
	shown := 0
	tables.ReverseIterate("", "", func(_ string, v any) bool {
		shown++
		if shown > 30 {
			return true // newest 30 only
		}
		t := v.(*Table)
		sb.WriteString("| [" + escape(t.Name) + "](" + page("table/"+strconv.Itoa(t.ID)) + ") | " +
			strconv.Itoa(len(t.Members)) + " | " + strconv.Itoa(len(t.BetIDs)) + " | " + who(t, t.Owner) + " |\n")
		return false
	})
	return sb.String()
}

func renderTable(t *Table) string {
	var sb strings.Builder
	id := strconv.Itoa(t.ID)
	sb.WriteString("[← All tables](" + home() + ")\n\n")
	sb.WriteString("# 🍺 " + escape(t.Name) + "\n\n")
	sb.WriteString("Table #" + id + " · owner " + who(t, t.Owner) + " · " + strconv.Itoa(len(t.Members)) + " members\n\n")
	sb.WriteString("[🎲 New bet](" + call("CreateBet", "tableID", id) + ") · ")
	sb.WriteString("[👋 Add member (owner only)](" + call("AddMember", "tableID", id) + ") · ")
	sb.WriteString("[✏️ Change your nickname](" + call("SetNickname", "tableID", id) + ")\n\n")

	// Leaderboard, sorted by net winnings.
	sb.WriteString("## 🏆 Leaderboard\n\n")
	var rows []row
	for _, m := range t.Members {
		s := &Stats{}
		if v := t.Stats.Get(m.String()); v != nil {
			s = v.(*Stats)
		}
		rows = append(rows, row{m, s})
	}
	for i := 1; i < len(rows); i++ { // insertion sort, highest net first
		for j := i; j > 0 && rows[j].s.Net > rows[j-1].s.Net; j-- {
			rows[j], rows[j-1] = rows[j-1], rows[j]
		}
	}
	sb.WriteString("| # | Member | Net | W | L | D | Disputes lost | Judged | |\n|---|---|---|---|---|---|---|---|---|\n")
	for i, r := range rows {
		liar := strconv.Itoa(r.s.DisputesLost)
		if r.s.DisputesLost > 0 {
			liar = "🚩 " + liar
		}
		sb.WriteString("| " + strconv.Itoa(i+1) + " | " + who(t, r.addr) + " | " + gnot(r.s.Net, true) + " | " +
			strconv.Itoa(r.s.Wins) + " | " + strconv.Itoa(r.s.Losses) + " | " + strconv.Itoa(r.s.Draws) + " | " +
			liar + " | " + strconv.Itoa(r.s.Judged) + " | [🎲 Challenge](" + challenge(t, r.addr) + ") |\n")
	}

	sb.WriteString("\n## 🎲 Bets\n\n")
	if len(t.BetIDs) == 0 {
		sb.WriteString("_No bets yet._\n")
		return sb.String()
	}
	sb.WriteString("| Bet | Players | Stake | Status |\n|---|---|---|---|\n")
	for i := len(t.BetIDs) - 1; i >= 0 && i >= len(t.BetIDs)-30; i-- { // newest 30
		b := mustBet(t.BetIDs[i])
		sb.WriteString("| [" + escape(b.Title) + "](" + page("bet/"+strconv.Itoa(b.ID)) + ") | " +
			who(t, b.PlayerA) + " vs " + who(t, b.PlayerB) + " | " + gnot(b.Stake, false) + " | " + statusBadge(t, b) + " |\n")
	}
	return sb.String()
}

func renderBet(b *Bet) string {
	var sb strings.Builder
	id := strconv.Itoa(b.ID)
	t := mustTable(b.TableID)
	sb.WriteString("[← " + escape(t.Name) + "](" + page("table/"+strconv.Itoa(t.ID)) + ")\n\n")
	sb.WriteString("# 🎲 " + escape(b.Title) + "\n\n")
	sb.WriteString("**Status: " + statusBadge(t, b) + "**\n\n")
	if hint := nextStep(t, b); hint != "" {
		sb.WriteString("> 👉 " + hint + "\n\n")
	}

	sb.WriteString("| | Player A | Player B |\n|---|---|---|\n")
	sb.WriteString("| Who | " + who(t, b.PlayerA) + " | " + who(t, b.PlayerB) + " |\n")
	sb.WriteString("| Stake | " + gnot(b.Stake, false) + " | " + gnot(b.Stake, false) + " |\n")
	sb.WriteString("| Honesty bond | " + gnot(b.Bond, false) + " | " + gnot(b.Bond, false) + " |\n")
	sb.WriteString("| Reported | " + result(t, b, b.ReportA) + " | " + result(t, b, b.ReportB) + " |\n\n")
	sb.WriteString("Pot: **" + gnot(2*b.Stake, false) + "**\n\n")
	aw, bw, dr := headToHead(t, b.PlayerA, b.PlayerB)
	if aw+bw+dr > 0 {
		sb.WriteString("Head to head at this table: " + plain(t, b.PlayerA) + " **" + strconv.Itoa(aw) + "** · " +
			plain(t, b.PlayerB) + " **" + strconv.Itoa(bw) + "** · draws **" + strconv.Itoa(dr) + "**\n\n")
	}
	if b.Status == StatusSettled || b.Status == StatusRefunded {
		loser := b.PlayerA
		if b.Final == ResultA {
			loser = b.PlayerB
		}
		other := b.PlayerB
		if loser == b.PlayerB {
			other = b.PlayerA
		}
		sb.WriteString("[🔁 Run it back](" + callSend("CreateBet", strconv.FormatInt(b.Stake+b.Bond, 10)+"ugnot", "tableID", strconv.Itoa(t.ID),
			"title", rematchTitle(b.Title), "opponentName", nameOrAddr(t, other),
			"stake", strconv.FormatInt(b.Stake, 10)) + ") _(for " + plain(t, loser) + ")_\n\n")
	}

	send := strconv.FormatInt(b.Stake+b.Bond, 10) + "ugnot"
	switch b.Status {
	case StatusOpen:
		sb.WriteString("### Actions\n\n")
		sb.WriteString("- Player B: [✅ Accept and lock " + gnot(b.Stake+b.Bond, false) + "](" +
			callSend("AcceptBet", send, "betID", id) + ")\n")
		sb.WriteString("- Player A: [❌ Cancel and refund](" + call("CancelBet", "betID", id) + ")\n")
	case StatusLive:
		sb.WriteString("### Report the result\n\n")
		sb.WriteString("[" + plain(t, b.PlayerA) + " won](" + call("Report", "betID", id, "result", ResultA) + ") · ")
		sb.WriteString("[" + plain(t, b.PlayerB) + " won](" + call("Report", "betID", id, "result", ResultB) + ") · ")
		sb.WriteString("[Draw](" + call("Report", "betID", id, "result", ResultDraw) + ")\n\n")
		if (b.ReportA == "") != (b.ReportB == "") {
			when := b.FirstReportAt.Add(ReportWindow)
			sb.WriteString("_One player has reported. The other has until " + when.UTC().Format(time.RFC822) +
				" to answer, then either player can [⚖️ send it to the judges](" + call("Escalate", "betID", id) + ")._\n")
		}
	case StatusDisputed:
		sb.WriteString("### ⚖️ Judges are voting\n\n")
		sb.WriteString("Players disagree. Judges (table members with no money in this bet) decide. ")
		need := len(b.Judges)/2 + 1
		sb.WriteString("A result needs **" + strconv.Itoa(need) + " of " + strconv.Itoa(len(b.Judges)) + "** votes. ")
		sb.WriteString("Voting closes " + b.Deadline.UTC().Format(time.RFC822) + ".\n\n")
		sb.WriteString("Votes so far: " + plain(t, b.PlayerA) + " won **" + strconv.Itoa(b.countVotes(ResultA)) + "** · " + plain(t, b.PlayerB) + " won **" +
			strconv.Itoa(b.countVotes(ResultB)) + "** · Draw **" + strconv.Itoa(b.countVotes(ResultDraw)) + "**\n\n")
		sb.WriteString("Judges: [Vote " + plain(t, b.PlayerA) + " won](" + call("Vote", "betID", id, "result", ResultA) + ") · ")
		sb.WriteString("[Vote " + plain(t, b.PlayerB) + " won](" + call("Vote", "betID", id, "result", ResultB) + ") · ")
		sb.WriteString("[Vote draw](" + call("Vote", "betID", id, "result", ResultDraw) + ")\n\n")
		sb.WriteString("_No majority by the deadline? Anyone can [refund everyone](" + call("ExpireDispute", "betID", id) + ")._\n")
	}

	if b.Status == StatusOpen {
		preview := t.judgesFor(b.PlayerA, b.PlayerB)
		sb.WriteString("\n### ⚖️ Judges if accepted\n\n")
		if len(preview) == 0 {
			sb.WriteString("_Nobody else is at this table, so a disagreement would be refunded._\n")
		}
		for _, j := range preview {
			sb.WriteString("- " + who(t, j) + "\n")
		}
	}

	if len(b.Judges) > 0 {
		sb.WriteString("\n### ⚖️ Judges\n\n_Fixed when the bet was accepted. Only used if the players disagree._\n\n")
		for _, j := range b.Judges {
			vote := "not voted"
			if v, ok := b.Votes.Get(j.String()).(string); ok {
				vote = result(t, b, v)
			}
			sb.WriteString("- " + who(t, j) + ": " + vote + "\n")
		}
	}

	if len(b.Payouts) > 0 {
		sb.WriteString("\n### 💸 Payouts\n\n| To | Amount | Why |\n|---|---|---|\n")
		for _, p := range b.Payouts {
			sb.WriteString("| " + who(t, p.To) + " | " + gnot(p.Amount, false) + " | " + p.Why + " |\n")
		}
	}
	return sb.String()
}

type row struct {
	addr address
	s    *Stats
}

// nextStep tells visitors what the bet is waiting for.
func nextStep(t *Table, b *Bet) string {
	switch b.Status {
	case StatusOpen:
		return "Waiting for " + plain(t, b.PlayerB) + " to accept and lock " + gnot(b.Stake+b.Bond, false) + "."
	case StatusLive:
		switch {
		case b.ReportA == "" && b.ReportB == "":
			return "Game on! After the game, both " + plain(t, b.PlayerA) + " and " + plain(t, b.PlayerB) + " report the result."
		case b.ReportA == "":
			return "Waiting for " + plain(t, b.PlayerA) + " to report."
		default:
			return "Waiting for " + plain(t, b.PlayerB) + " to report."
		}
	case StatusDisputed:
		return "The players disagree. Judges, it's your call."
	}
	return ""
}

// headToHead counts settled results between two players at a table,
// from a's point of view: a's wins, b's wins, draws.
func headToHead(t *Table, a, b address) (int, int, int) {
	aw, bw, dr := 0, 0, 0
	for _, id := range t.BetIDs {
		x := mustBet(id)
		if x.Status != StatusSettled {
			continue
		}
		var winner address
		switch x.Final {
		case ResultA:
			winner = x.PlayerA
		case ResultB:
			winner = x.PlayerB
		}
		pair := (x.PlayerA == a && x.PlayerB == b) || (x.PlayerA == b && x.PlayerB == a)
		if !pair {
			continue
		}
		switch winner {
		case a:
			aw++
		case b:
			bw++
		default:
			dr++
		}
	}
	return aw, bw, dr
}

func rematchTitle(title string) string {
	if !strings.HasPrefix(title, "Rematch: ") {
		title = "Rematch: " + title
	}
	if len(title) > 140 {
		title = title[:140]
	}
	return title
}

func nameOrAddr(t *Table, a address) string {
	if n := t.Nick(a); n != "" {
		return n
	}
	return a.String()
}

func count(n int, word string) string {
	if n == 1 {
		return "**1** " + word
	}
	return "**" + strconv.Itoa(n) + "** " + word + "s"
}

// challenge links to CreateBet with the table and opponent filled in.
func challenge(t *Table, a address) string {
	return call("CreateBet", "tableID", strconv.Itoa(t.ID), "opponentName", nameOrAddr(t, a))
}

// ---------------------------------------------------------------------------
// Formatting helpers

func statusBadge(t *Table, b *Bet) string {
	switch b.Status {
	case StatusOpen:
		return "🟡 waiting for " + plain(t, b.PlayerB)
	case StatusLive:
		return "🟢 live"
	case StatusDisputed:
		return "⚖️ disputed"
	case StatusSettled:
		return "✅ settled: " + result(t, b, b.Final)
	case StatusCancelled:
		return "❌ cancelled"
	case StatusRefunded:
		return "↩️ refunded"
	}
	return b.Status.String()
}

// result describes a reported/voted result using the players' nicknames.
func result(t *Table, b *Bet, r string) string {
	switch r {
	case ResultA:
		return plain(t, b.PlayerA) + " won"
	case ResultB:
		return plain(t, b.PlayerB) + " won"
	}
	return showReport(r)
}

// plain is a nickname (or short address) without markdown, for link text.
func plain(t *Table, a address) string {
	if n := t.Nick(a); n != "" {
		return escape(n)
	}
	s := a.String()
	return s[:7] + "…" + s[len(s)-4:]
}

func showReport(r string) string {
	switch r {
	case ResultA:
		return "A won"
	case ResultB:
		return "B won"
	case ResultDraw:
		return "draw"
	}
	return "—"
}

// gnot formats ugnot as GNOT with up to 6 decimals.
func gnot(u int64, signed bool) string {
	sign := ""
	if u < 0 {
		sign = "-"
		u = -u
	} else if signed && u > 0 {
		sign = "+"
	}
	whole := u / 1_000_000
	frac := u % 1_000_000
	s := strconv.FormatInt(whole, 10)
	if frac != 0 {
		f := strconv.FormatInt(frac, 10)
		for len(f) < 6 {
			f = "0" + f
		}
		s += "." + strings.TrimRight(f, "0")
	}
	return sign + s + " GNOT"
}

// who shows a member's nickname at a table, falling back to a short address.
func who(t *Table, a address) string {
	if n := t.Nick(a); n != "" {
		return "**" + escape(n) + "**"
	}
	return short(a)
}

func short(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return "`" + s + "`"
	}
	return "`" + s[:7] + "…" + s[len(s)-4:] + "`"
}

func escape(s string) string {
	r := strings.NewReplacer("|", "\\|", "[", "\\[", "]", "\\]", "<", "&lt;", ">", "&gt;", "\n", " ")
	return r.Replace(s)
}

func prefix() string {
	return strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), runtime.ChainDomain())
}

func home() string           { return prefix() }
func page(sub string) string { return prefix() + ":" + sub }

// call builds a gnoweb transaction link: /r/...$help&func=Fn&k=v
func call(fn string, kv ...string) string {
	return callSend(fn, "", kv...)
}

func callSend(fn, send string, kv ...string) string {
	q := url.Values{}
	for i := 0; i+1 < len(kv); i += 2 {
		q.Add(kv[i], kv[i+1])
	}
	if send != "" {
		q.Add(".send", send)
	}
	link := prefix() + "$help&func=" + fn
	if enc := q.Encode(); enc != "" {
		link += "&" + enc
	}
	return link
}
