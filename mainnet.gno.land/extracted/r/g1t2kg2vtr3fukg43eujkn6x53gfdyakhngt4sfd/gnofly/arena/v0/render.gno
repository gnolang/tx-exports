package arena

import (
	"strings"
	"time"

	"gno.land/p/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/arena/payout/v0"
)

// Render returns the state of the arenas as markdown, for gnoweb:
//
//	""            the open arenas and the last games played
//	"arena/<id>"  one arena: its rules, lobby and game, or its result
//	"earnings"    the top winners
//
// Everything printed here was validated against a narrow charset when it was
// written (see spec.gno and validate.gno), or is an address the chain gave
// the realm. The only caller-supplied value, the id of an arena page, is
// printed only if it is a valid id. Nothing needs markdown escaping.
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case path == "earnings":
		return renderEarnings()
	case strings.HasPrefix(path, "arena/"):
		id := strings.TrimPrefix(path, "arena/")
		if a := getArena(id); a != nil {
			return renderArena(id, a)
		}
		if r, ok := resultOf(id); ok {
			return renderResult(id, r)
		}
	}
	return "# gnofly arenas\n\nPage not found. Go back to the [overview](" + link("") + ").\n"
}

// link returns the gnoweb URL of a Render path of this realm.
func link(path string) string {
	if path == "" {
		return webPath
	}
	return webPath + ":" + path
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# gnofly arenas\n\n")
	b.WriteString("Paid games of gnofly, a multiplayer plane game, created by players at [gnofly.xyz/arena](https://gnofly.xyz/arena).\n")
	b.WriteString("A pilot pays the entry price to join, the realm keeps the stakes until the game is over, then credits them by the rule of its mode. Winners claim what they are owed with Claim.\n")
	b.WriteString("The house takes " + percent(feeBps) + " of what a settled game pays out.\n\n")

	b.WriteString("## Open arenas\n\n")
	if arenas.Size() == 0 {
		b.WriteString("No arena has players right now.\n\n")
	} else {
		b.WriteString("| Arena | Mode | Entry | Seats | Lives | Time | Kill target | Pilots |\n|---|---|---|---|---|---|---|---|\n")
		arenas.Iterate("", "", func(id string, v any) bool {
			a := v.(*arena)
			pilots := itoa(int64(len(a.lobby))) + " waiting"
			if a.round != nil {
				pilots = itoa(int64(len(a.round.players))) + " playing"
			}
			b.WriteString("| [" + id[:8] + "](" + link("arena/"+id) + ") | " + a.mode + " | " + gnot(a.stake) +
				" | " + itoa(a.minSeats) + " to " + itoa(a.maxSeats) + " | " + itoa(a.lives) +
				" | " + itoa(a.seconds/60) + " min | " + targetCell(a.killTarget) + " | " + pilots + " |\n")
			return false
		})
		b.WriteByte('\n')
	}

	b.WriteString("## Last games\n\n")
	if len(closed) == 0 {
		b.WriteString("No game is over yet.\n\n")
	} else {
		b.WriteString("| Arena | Mode | Outcome | Pilots | Pot | Fee |\n|---|---|---|---|---|---|\n")
		for i := len(closed) - 1; i >= 0 && i >= len(closed)-10; i-- {
			r, _ := resultOf(closed[i])
			b.WriteString("| [" + closed[i][:8] + "](" + link("arena/"+closed[i]) + ") | " + r.mode + " | " + r.outcome +
				" | " + itoa(r.players) + " | " + gnot(r.pot) + " | " + gnot(r.fee) + " |\n")
		}
		b.WriteByte('\n')
	}

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| In escrow | " + gnot(escrowed) + " |\n")
	b.WriteString("| Refund delay | " + itoa(refundDelay) + " s |\n\n")
	b.WriteString("- [Earnings](" + link("earnings") + "): " + itoa(int64(len(winners.addrs))) + " ranked pilots\n")
	return b.String()
}

func renderArena(id string, a *arena) string {
	var b strings.Builder
	b.WriteString("# Arena " + id[:8] + "\n\n")
	b.WriteString("Mode `" + a.mode + "`: " + modeDoc(a.mode) + "\n\n")

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Id | `" + id + "` |\n")
	b.WriteString("| Entry | " + gnot(a.stake) + " |\n")
	b.WriteString("| Seats | " + itoa(a.minSeats) + " to " + itoa(a.maxSeats) + " |\n")
	b.WriteString("| Lives | " + itoa(a.lives) + " |\n")
	b.WriteString("| Game time | " + itoa(a.seconds/60) + " min |\n")
	b.WriteString("| Kill target | " + targetCell(a.killTarget) + " |\n")
	b.WriteString("| Created by | " + a.creator.String() + " |\n")
	b.WriteString("| Takes entries until | " + clock(a.created+entryWindow) + " |\n\n")

	if a.round == nil {
		b.WriteString("## Lobby\n\n")
		b.WriteString("Pilots who paid and wait for the game. They can leave with `Leave` until it starts.\n\n")
		b.WriteString("| Seat | Pilot |\n|---|---|\n")
		for i, player := range a.lobby {
			b.WriteString("| " + itoa(int64(i+1)) + " | " + player.String() + " |\n")
		}
	} else {
		r := a.round
		b.WriteString("## Game\n\n")
		b.WriteString("Started at " + clock(r.startedAt) + " with " + itoa(int64(len(r.players))) +
			" pilots and a pot of " + gnot(a.stake*int64(len(r.players))) + ".\n")
		b.WriteString("If the referee does not settle it, anyone can send the stakes back with `RefundRound` from " +
			clock(r.startedAt+a.seconds+refundDelay) + ".\n\n")
		b.WriteString("| Pilot |\n|---|\n")
		for _, player := range r.players {
			b.WriteString("| " + player.String() + " |\n")
		}
	}
	b.WriteString("\n[Earnings](" + link("earnings") + ") | [Overview](" + link("") + ")\n")
	return b.String()
}

func renderResult(id string, r result) string {
	var b strings.Builder
	b.WriteString("# Arena " + id[:8] + "\n\n")
	b.WriteString("Mode `" + r.mode + "`, " + itoa(r.players) + " pilots, closed at " + clock(r.closedAt) + ": " + r.outcome + ".\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Entry | " + gnot(r.stake) + " |\n")
	b.WriteString("| Pot | " + gnot(r.pot) + " |\n")
	b.WriteString("| Fee | " + gnot(r.fee) + " |\n")
	b.WriteString("| Paid | " + paidCell(r) + " |\n")
	b.WriteString("\n[Overview](" + link("") + ")\n")
	return b.String()
}

// targetCell formats a kill target: most arenas end on the clock only.
func targetCell(n int64) string {
	if n == 0 {
		return "none"
	}
	return itoa(n) + " kills"
}

// paidCell lists who was paid what in a round, for a table cell.
func paidCell(r result) string {
	if r.outcome != outcomeSettled {
		return "every stake sent back"
	}
	if len(r.payouts) == 0 {
		return "nobody"
	}
	parts := make([]string, len(r.payouts))
	for i, p := range r.payouts {
		parts[i] = p.Address.String() + " " + gnot(p.Amount)
	}
	return strings.Join(parts, ", ")
}

func renderEarnings() string {
	var b strings.Builder
	b.WriteString("# gnofly arena earnings\n\n")
	b.WriteString("The top " + itoa(topSize) + " pilots by what they won above their own stakes, over every settled round.\n\n")
	if len(winners.addrs) == 0 {
		b.WriteString("Nobody won anything yet.\n")
	} else {
		b.WriteString("| Rank | Pilot | Won | Rounds |\n|---|---|---|---|\n")
		for i, addr := range winners.addrs {
			t := totalsOf(addr)
			b.WriteString("| " + itoa(int64(i+1)) + " | " + addr.String() +
				" | " + gnot(t.won) + " | " + itoa(t.rounds) + " |\n")
		}
	}
	b.WriteString("\n[Back to the overview](" + link("") + ")\n")
	return b.String()
}

// modeDoc is one sentence about the payout rule of a mode.
func modeDoc(mode string) string {
	switch mode {
	case payout.ModeBattleRoyale:
		return "the pot, less the fee, goes to the last pilot flying; when the clock runs out, to the pilot still in with the most kills."
	case payout.ModeDeathmatch:
		return "the pot, less the fee, goes to the top three by kills: 60%, 30% and 10%."
	}
	return "see the payout package."
}

// gnot formats an amount of ugnot in GNOT, without trailing zeros:
// 10000000 gives "10 GNOT", 9500000 gives "9.5 GNOT", 1 gives "0.000001 GNOT".
func gnot(ugnot int64) string {
	whole, frac := ugnot/1000000, ugnot%1000000
	if frac == 0 {
		return itoa(whole) + " GNOT"
	}
	decimals := itoa(1000000 + frac)[1:] // all six of them, zeros included
	end := len(decimals)
	for decimals[end-1] == '0' {
		end--
	}
	return itoa(whole) + "." + decimals[:end] + " GNOT"
}

// percent formats basis points as a percentage, without trailing zeros:
// 500 gives "5%", 250 gives "2.5%", 1 gives "0.01%".
func percent(bps int64) string {
	whole, frac := bps/100, bps%100
	switch {
	case frac == 0:
		return itoa(whole) + "%"
	case frac%10 == 0:
		return itoa(whole) + "." + itoa(frac/10) + "%"
	case frac < 10:
		return itoa(whole) + ".0" + itoa(frac) + "%"
	}
	return itoa(whole) + "." + itoa(frac) + "%"
}

// clock formats a block time in Unix seconds, in UTC.
func clock(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04:05") + " UTC"
}
