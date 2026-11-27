package arena

import (
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// blockSeconds is Onyx's approximate block time, for "about N days" hints.
const blockSeconds = 3.6

// seasonLine describes the current season's timing.
func seasonLine() string {
	if seasonStart == 0 {
		return ufmt.Sprintf("Season %d starts with the first match. [Past seasons](%s)", season, link("seasons"))
	}
	end := seasonStart + SeasonLength
	left := end - height()
	if left < 0 {
		left = 0
	}
	days := int(float64(left) * blockSeconds / 86400)
	return ufmt.Sprintf("Ends at block %d (about %d days). Ratings reset each season; the top 10 is kept. [Past seasons](%s)", end, days, link("seasons"))
}

// activeLeaderboard is the leaderboard without retired bots.
func activeLeaderboard() []*Bot {
	var out []*Bot
	for _, b := range leaderboard() {
		if !b.Retired {
			out = append(out, b)
		}
	}
	return out
}

func writeTournamentList(sb *strings.Builder, limit int) {
	if lastTID == 0 {
		sb.WriteString("No tournaments yet.\n\n")
		return
	}
	n := 0
	tournaments.ReverseIterate("", "", func(_ string, v any) bool {
		t := v.(*Tournament)
		extra := ""
		if t.Status == Done && t.Winner != "" {
			extra = ", won by " + t.Winner
		}
		sb.WriteString(ufmt.Sprintf("- [#%d %s](%s): %d/%d bots, %s%s\n",
			t.ID, t.Name, link("tournament/"+strconv.Itoa(t.ID)), len(t.Entrants), t.Capacity, t.Status.String(), extra))
		n++
		return limit > 0 && n >= limit
	})
	sb.WriteString("\n")
}

func renderTournaments() string {
	var sb strings.Builder
	sb.WriteString("# Tournaments\n\n")
	sb.WriteString("Round-robins of 2 to 8 bots: everyone plays everyone once. 3 points for a win, 1 for a draw; ties go to gold difference.\n\n")
	sb.WriteString(ufmt.Sprintf("[Open a tournament](%s)\n\n", tx.Call("CreateTournament", "name", "", "capacity", "8")))
	writeTournamentList(&sb, 0)
	sb.WriteString("[Back to the arena](" + link("") + ")\n")
	return sb.String()
}

func renderTournament(t *Tournament) string {
	var sb strings.Builder
	id := strconv.Itoa(t.ID)
	sb.WriteString(ufmt.Sprintf("# Tournament #%d: %s\n\n", t.ID, t.Name))
	sb.WriteString(ufmt.Sprintf("**%s** · %d/%d bots · created by `%s`\n\n", t.Status.String(), len(t.Entrants), t.Capacity, t.Creator.String()))
	if t.Status == Done && t.Winner != "" {
		sb.WriteString(ufmt.Sprintf("**Winner: [%s](%s)**\n\n", t.Winner, link("bot/"+t.Winner)))
	}

	switch t.Status {
	case Open:
		sb.WriteString(ufmt.Sprintf("[Enter your bot](%s) · [Start (creator only)](%s)\n\n",
			tx.Call("JoinTournament", "id", id, "botName", ""), tx.Call("StartTournament", "id", id)))
	case Running:
		idx, inProgress := t.next()
		switch {
		case inProgress:
			mid := t.MatchIDs[idx]
			sb.WriteString(ufmt.Sprintf("Match [#%d](%s) is being played: finish it from its page.\n\n", mid, matchLink(mid)))
		case idx < len(t.Pairs):
			sb.WriteString(ufmt.Sprintf("Next: %s. [Play it](%s) · if a bot keeps that failing, [create it](%s) and use step mode from its page.\n\n",
				strings.Replace(t.Pairs[idx], "|", " vs ", 1), tx.Call("PlayTournament", "id", id), tx.Call("NextTournamentMatch", "id", id)))
		default:
			sb.WriteString(ufmt.Sprintf("All matches are played: [close the tournament](%s).\n\n", tx.Call("CloseTournament", "id", id)))
		}
	}

	if len(t.Entrants) > 0 {
		sb.WriteString("## Table\n\n| # | Bot | P | W | D | L | Gold | Pts |\n|---|---|---|---|---|---|---|---|\n")
		for i, r := range t.Standings() {
			sb.WriteString(ufmt.Sprintf("| %d | [%s](%s) | %d | %d | %d | %d | %d:%d | **%d** |\n",
				i+1, r.Bot, link("bot/"+r.Bot), r.Played, r.Wins, r.Draws, r.Losses, r.GoldFor, r.GoldAgainst, r.Points))
		}
		sb.WriteString("\n")
	}

	if len(t.Pairs) > 0 {
		sb.WriteString("## Schedule\n\n")
		for i, pair := range t.Pairs {
			vs := strings.Replace(pair, "|", " vs ", 1)
			if mid := t.MatchIDs[i]; mid != 0 {
				sb.WriteString(ufmt.Sprintf("%d. [%s](%s)\n", i+1, mustMatch(mid).Summary(), matchLink(mid)))
			} else {
				sb.WriteString(ufmt.Sprintf("%d. %s\n", i+1, vs))
			}
		}
		sb.WriteString("\n")
	}
	sb.WriteString("[All tournaments](" + link("tournaments") + ") · [Back to the arena](" + link("") + ")\n")
	return sb.String()
}

func renderSeasons() string {
	var sb strings.Builder
	sb.WriteString("# Seasons\n\n")
	sb.WriteString(ufmt.Sprintf("Season %d is running. %s\n\n", season, seasonLine()))
	if season == 1 {
		sb.WriteString("No finished seasons yet.\n\n")
	}
	for n := season - 1; n >= 1; n-- {
		sb.WriteString(ufmt.Sprintf("## Season %d\n\n", n))
		top := PastSeason(n)
		if len(top) == 0 {
			sb.WriteString("Nobody played.\n\n")
			continue
		}
		sb.WriteString("| # | Bot | Elo | W-L-D |\n|---|---|---|---|\n")
		for i, s := range top {
			sb.WriteString(ufmt.Sprintf("| %d | [%s](%s) | %d | %d-%d-%d |\n", i+1, s.Bot, link("bot/"+s.Bot), s.Rating, s.Wins, s.Losses, s.Draws))
		}
		sb.WriteString("\n")
	}
	sb.WriteString("[Back to the arena](" + link("") + ")\n")
	return sb.String()
}
