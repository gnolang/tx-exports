package arena

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g188vafzutzvlfw6wt7u3s62xtuvm0epmu8ufmfz/gnomepit/engine"
)

const notFound = "# Not found\n\nThe arena has no page at this path.\n"

// Render serves the board of open challenges at "", one player's matches at
// "player/<address>", and one match at "match/<id>".
func Render(path string) string {
	switch {
	case path == "":
		return renderBoard()
	case strings.HasPrefix(path, "player/"):
		player := address(strings.TrimPrefix(path, "player/"))
		if !canonical(player) {
			return notFound
		}
		return renderPlayer(player)
	case strings.HasPrefix(path, "match/"):
		rules := engine.ProofOfConcept()
		n, m, ok := lookup(rules, strings.TrimPrefix(path, "match/"))
		if !ok {
			return notFound
		}
		return renderMatch(m.view(rules, n, time.Now().Unix()))
	}
	return notFound
}

func renderBoard() string {
	var b strings.Builder
	b.WriteString("# Gnomepit arena\n\nOpen challenges, newest first.\n\n")
	list := Open(0, maxPage)
	if len(list) == 0 {
		b.WriteString("No open challenge.\n")
	}
	for _, c := range list {
		who := "open to anyone"
		if c.Opponent != "" {
			who = "reserved for " + c.Opponent
		}
		b.WriteString("- " + matchLink(c.ID) + ": " + c.Clan + ", posted by " + c.Challenger + ", " + who + ", expires " + date(c.Expires) + "\n")
	}
	return b.String()
}

func renderPlayer(player address) string {
	var b strings.Builder
	b.WriteString("# Matches of " + player.String() + "\n\n")
	list := Matches(player, 0, maxPage)
	if len(list) == 0 {
		b.WriteString("No match.\n")
	}
	for _, s := range list {
		b.WriteString("- " + matchLink(s.ID) + ": " + s.ChallengerClan + " against " + orNone(s.AcceptorClan) + ", " + s.Phase + "\n")
	}
	return b.String()
}

func renderMatch(v MatchView) string {
	var b strings.Builder
	b.WriteString("# Match " + v.ID + "\n\n")
	b.WriteString(v.ChallengerClan + " (" + v.Challenger + ") against " + orNone(v.AcceptorClan))
	if v.Acceptor != "" {
		b.WriteString(" (" + v.Acceptor + ")")
	}
	b.WriteString("\n\n")
	switch v.Phase {
	case phaseOpen:
		who := "open to anyone"
		if v.Opponent != "" {
			who = "reserved for " + v.Opponent
		}
		b.WriteString("Open challenge, " + who + ", until " + date(v.Deadline) + ".\n")
	case phaseReveal, phasePlay:
		b.WriteString("Round " + strconv.Itoa(v.Round) + ", waiting for " + v.ToMove + " until " + date(v.Deadline) + ".\n")
	case phaseEnded:
		b.WriteString("Over: " + outcome(v.Result, v.Reason) + ".\n")
	default:
		b.WriteString(strings.ToUpper(v.Phase[:1]) + v.Phase[1:] + ".\n")
	}
	if len(v.HP) > 0 {
		b.WriteString("\n| HP after | Challenger | Acceptor |\n|---|---|---|\n")
		for i, hp := range v.HP {
			b.WriteString("| Round " + strconv.Itoa(i+1) + " | " + strconv.Itoa(hp[0]) + " | " + strconv.Itoa(hp[1]) + " |\n")
		}
	}
	return b.String()
}

func outcome(result, reason string) string {
	winner := "the challenger won"
	switch result {
	case "b":
		winner = "the acceptor won"
	case "draw":
		winner = "a draw"
	}
	switch reason {
	case "hp":
		return winner + " on HP"
	case "knockout":
		return winner + " by knockout"
	case "resign":
		return winner + " by resignation"
	}
	return winner + " by forfeit"
}

func matchLink(id string) string {
	return "[Match " + id + "](" + strings.TrimPrefix(self, "gno.land") + ":match/" + id + ")"
}

func date(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04 UTC")
}

func orNone(s string) string {
	if s == "" {
		return "nobody yet"
	}
	return s
}
