package taproom

// Render pages for gnoweb. Avatars are SVG data URIs from the avatar package, which gnoweb
// allows in markdown images. Paths: "" (home), "board/<name>", "player/<address>", "round/<id>".
// Action links (txlink) open gnoweb's call form with the round and amount filled in, so the game
// can be played from gnoweb with Adena and no other site.

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1vxsg6ht4nklaud70yaszcgkhc9ttancr9nlzzq/avatar/v0"
	"gno.land/p/moul/txlink/v0"
)

// boardPageRows caps a board page: each avatar costs about 100M gas, and a Render query may use 3B.
const boardPageRows = 10

var rankNames = []string{"Newcomer", "Regular", "Sharp", "Oracle", "Legend"}
var rankAt = []int64{0, 100, 500, 1500, 4000}

func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case path == "":
		return renderHome()
	case len(parts) == 2 && parts[0] == "board":
		return renderBoard(parts[1])
	case len(parts) == 2 && parts[0] == "player":
		return renderPlayer(address(parts[1]))
	case len(parts) == 2 && parts[0] == "round":
		if id, err := strconv.Atoi(parts[1]); err == nil && id >= 0 && id < roundCount {
			return renderRound(getRound(id))
		}
	}
	return "# Not found\n\nNo such page. [Back to the taproom](" + link("") + ")\n"
}

func renderHome() string {
	var sb strings.Builder
	t := now()
	sb.WriteString("# Taproom\n\nA tavern of short mind games. Seal a number from 0 to 100; the pick closest to two thirds of the crowd's average takes the pot. 1 GNOT a seat, 0.5% to the tavern on completed rounds.\n\n")

	sb.WriteString("## Open tables\n\n")
	open := 0
	openRounds.ReverseIterate("", "", func(k string, _ any) bool {
		id, _ := strconv.Atoi(k)
		r := getRound(id)
		open++
		sb.WriteString("- [Round " + strconv.Itoa(r.ID) + "](" + link("round/"+strconv.Itoa(r.ID)) + "): " +
			strconv.Itoa(r.Seal.Count()) + " of " + strconv.Itoa(maxPlayers) + " seats, pot " + gnot(r.Pot) + ", " + phaseLine(r, t) + "\n")
		return open >= 10
	})
	if open == 0 {
		sb.WriteString("No open tables right now.\n")
	}
	sb.WriteString("\nOpen a table (Oak, free): " +
		action("Quick, 2 + 2 min", txlink.NewLink("NewRound").AddArgs("commitSecs", "120", "revealSecs", "120", "boardSkin", "0")) + " · " +
		action("Standard, 30 + 30 min", txlink.NewLink("NewRound").AddArgs("commitSecs", "1800", "revealSecs", "1800", "boardSkin", "0")) + " · " +
		action("Daily, 12 + 12 h", txlink.NewLink("NewRound").AddArgs("commitSecs", "43200", "revealSecs", "43200", "boardSkin", "0")) + "\n")

	sb.WriteString("\n## Recent results\n\n")
	shown := 0
	for i := len(recentSettled) - 1; i >= 0; i-- {
		r := getRound(recentSettled[i])
		shown++
		sb.WriteString("- [Round " + strconv.Itoa(r.ID) + "](" + link("round/"+strconv.Itoa(r.ID)) + "): " + resultLine(r) + "\n")
	}
	if shown == 0 {
		sb.WriteString("No completed rounds yet.\n")
	}

	sb.WriteString("\n## Leaderboards\n\n")
	writeBoardTable(&sb, "points", 5)
	sb.WriteString("\nAll boards:")
	for i, b := range boards {
		if i > 0 {
			sb.WriteString(" ·")
		}
		sb.WriteString(" [" + b[1] + "](" + link("board/"+b[0]) + ")")
	}
	sb.WriteString("\n")
	return sb.String()
}

func renderBoard(name string) string {
	for _, b := range boards {
		if b[0] == name {
			var sb strings.Builder
			sb.WriteString("# " + b[1] + "\n\n")
			writeBoardTable(&sb, name, boardPageRows)
			sb.WriteString("\n[Back to the taproom](" + link("") + ")\n")
			return sb.String()
		}
	}
	// the name comes from the URL, so it is not echoed back into the page
	return "# Not found\n\nNo such board: use points, net, sharp, streak or style. [Back to the taproom](" + link("") + ")\n"
}

func writeBoardTable(sb *strings.Builder, name string, limit int) {
	var col string
	for _, b := range boards {
		if b[0] == name {
			col = b[2]
		}
	}
	rows := board(name, limit)
	if len(rows) == 0 {
		sb.WriteString("Nobody on this board yet.\n")
		return
	}
	sb.WriteString("| # | | Regular | " + col + " |\n|---|---|---|---|\n")
	for i, r := range rows {
		var v string
		switch name {
		case "points":
			v = i64(r.p.Lifetime)
		case "net":
			v = gnot(r.p.Net)
		case "sharp":
			v = hundredths(sharp100(r.p))
		case "streak":
			v = i64(r.p.BestStreak)
		case "style":
			v = i64(styleOf(r.p.Equipped))
		}
		sb.WriteString("| " + strconv.Itoa(i+1) + " | " + gnome(r.addr, r.p.Equipped) + " | [" + short(r.addr) + "](" + link("player/"+r.addr.String()) + ") | " + v + " |\n")
	}
}

func renderPlayer(a address) string {
	v := players.Get(a.String())
	if v == nil {
		return "# Not found\n\nThis address has not played yet. [Back to the taproom](" + link("") + ")\n"
	}
	p := v.(*Player)
	rank := 0
	for i, at := range rankAt {
		if p.Lifetime >= at {
			rank = i
		}
	}
	var sb strings.Builder
	sb.WriteString("# Regular " + short(a) + "\n\n" + gnome(a, p.Equipped) + "\n\n")
	sb.WriteString("- Rank: " + rankNames[rank] + "\n")
	sb.WriteString("- Points: " + i64(p.Lifetime) + " lifetime, " + i64(p.Lifetime-p.Spent) + " to spend\n")
	sb.WriteString("- Weekly streak: " + i64(p.Streak) + " (best " + i64(p.BestStreak) + "), freezes held: " + strconv.Itoa(p.Freezes) + "\n")
	sb.WriteString("- Wins: " + i64(p.Wins) + "\n")
	sb.WriteString("- Net coins: " + gnot(p.Net) + "\n")
	if p.Scored > 0 {
		sb.WriteString("- Average distance to the target: " + hundredths(sharp100(p)) + " over " + i64(p.Scored) + plural(p.Scored, " round", " rounds") + "\n")
	}
	sb.WriteString("- Style score: " + i64(styleOf(p.Equipped)) + "\n")
	if c := Claimable(a); c > 0 {
		sb.WriteString("\n" + gnot(c) + " to claim: " + action("Claim", txlink.NewLink("Claim")) + " (signed by this address)\n")
	}
	sb.WriteString("\n[Back to the taproom](" + link("") + ")\n")
	return sb.String()
}

func renderRound(r *Round) string {
	var sb strings.Builder
	t := now()
	sb.WriteString("# Round " + strconv.Itoa(r.ID) + "\n\n")
	sb.WriteString(strconv.Itoa(r.Seal.Count()) + " of " + strconv.Itoa(maxPlayers) + " seats, pot " + gnot(r.Pot) + ", " + phaseLine(r, t) + ".\n\n")
	if r.Settled {
		sb.WriteString(resultLine(r) + "\n\n")
		if len(r.Winners) > 0 {
			sum, n := revealedSum(r)
			sb.WriteString("Target: " + hundredths(round2(r.Num*sum*100, r.Den*n)) + " (2/3 of the average " + hundredths(round2(sum*100, n)) + ")\n\n")
		}
	}
	sb.WriteString("| | Regular | Pick | Status |\n|---|---|---|---|\n")
	for _, p := range r.Seal.Players() {
		pick, status := "sealed", "sealed"
		if r.Seal.IsRevealed(p) {
			pick = i64(r.Seats[seatOf(r, p)].Pick)
			status = "revealed"
		}
		if r.Settled {
			switch {
			case isWinner(r, p):
				status = "winner"
			case len(r.Winners) == 0:
				status = "refunded"
			case status == "sealed":
				status = "forfeit"
				pick = "not revealed"
			}
		}
		var equipped [4]int
		if v := players.Get(p.String()); v != nil {
			equipped = v.(*Player).Equipped
		}
		sb.WriteString("| " + gnome(p, equipped) + " | [" + short(p) + "](" + link("player/"+p.String()) + ") | " + pick + " | " + status + " |\n")
	}
	sb.WriteString("\n" + roundActions(r, t) + "\n[Back to the taproom](" + link("") + ")\n")
	return sb.String()
}

// roundActions is what anyone can do at this table now, as gnoweb call links.
func roundActions(r *Round, t int64) string {
	id := strconv.Itoa(r.ID)
	switch {
	case r.Settled:
		return "Winners and refunded players: " + action("Claim", txlink.NewLink("Claim")) + "\n"
	case t < r.Seal.CommitEnd:
		if r.Seal.Count() >= maxPlayers {
			return "The table is full.\n"
		}
		return "Take a seat: " + action("Join for 1 GNOT", txlink.NewLink("Join").AddArgs("roundID", id, "commit", "").SetSend("1000000ugnot")) +
			". The commit is `CommitHash(" + id + ", <your address>, <pick>, <salt>)` from this realm's " +
			"[functions page](" + link("") + "$help); pick 0 to 100, salt 16 to 128 characters. Keep both: you need them to reveal.\n"
	case t < r.Seal.RevealEnd:
		return "Seated players: " + action("Reveal", txlink.NewLink("Reveal").AddArgs("roundID", id, "pick", "", "salt", "")) +
			" with the pick and salt you sealed. A seat that does not reveal forfeits its 1 GNOT.\n"
	}
	return "Anyone can " + action("Settle", txlink.NewLink("Settle").AddArgs("roundID", id)) + " this round now.\n"
}

// ---------- helpers ----------

func action(label string, b *txlink.TxBuilder) string {
	return "[" + label + "](" + b.URL() + ")"
}

func phaseLine(r *Round, t int64) string {
	if r.Settled {
		return "settled"
	}
	switch {
	case t < r.Seal.CommitEnd:
		return "sealing until " + clock(r.Seal.CommitEnd)
	case t < r.Seal.RevealEnd:
		return "revealing until " + clock(r.Seal.RevealEnd)
	}
	return "ready to settle (anyone can settle)"
}

func resultLine(r *Round) string {
	if len(r.Winners) == 0 {
		return "cancelled, fewer than 2 revealed; everyone refunded, no fee"
	}
	var names []string
	for _, w := range r.Winners {
		names = append(names, "["+short(w)+"]("+link("player/"+w.String())+") with "+i64(r.Seats[seatOf(r, w)].Pick))
	}
	return "won by " + strings.Join(names, " and ") + ", pot " + gnot(r.Pot) + ", fee " + gnot(r.Fee)
}

func revealedSum(r *Round) (sum, n int64) {
	for _, o := range r.Seal.Revealed() {
		sum += r.Seats[seatOf(r, o.Who)].Pick
		n++
	}
	return sum, n
}

func isWinner(r *Round, a address) bool {
	for _, w := range r.Winners {
		if w == a {
			return true
		}
	}
	return false
}

func gnome(a address, equipped [4]int) string {
	return "![gnome](" + avatar.DataURI(a, equipped) + ")"
}

// link points at a page of this realm in gnoweb.
func link(sub string) string {
	p := "/" + strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land/")
	if sub == "" {
		return p
	}
	return p + ":" + sub
}

func short(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "…" + s[len(s)-4:]
}

// gnot formats ugnot as GNOT without trailing zeros: 2985000 -> "2.985 GNOT".
func gnot(u int64) string {
	sign := ""
	if u < 0 {
		sign, u = "-", -u
	}
	s := sign + i64(u/1000000)
	if frac := u % 1000000; frac != 0 {
		f := strconv.FormatInt(frac+1000000, 10)[1:]
		s += "." + strings.TrimRight(f, "0")
	}
	return s + " GNOT"
}

// round2 divides num by den rounded to the nearest integer (both positive).
func round2(num, den int64) int64 {
	if den == 0 {
		return 0
	}
	return (num*10/den + 5) / 10
}

// hundredths formats 1778 as "17.78".
func hundredths(h int64) string {
	if h < 0 {
		return "-"
	}
	f := strconv.FormatInt(h%100+100, 10)[1:]
	return i64(h/100) + "." + f
}

func clock(ts int64) string {
	return time.Unix(ts, 0).UTC().Format("Jan 2 15:04 UTC")
}

func plural(n int64, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
