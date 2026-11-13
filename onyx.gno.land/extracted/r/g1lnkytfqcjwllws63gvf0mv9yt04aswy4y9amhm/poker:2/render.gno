package poker

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/poker/cards"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/poker/holdem"
)

func i64s(v int64) string { return "\"" + strconv.FormatInt(v, 10) + "\"" }
func itoa(v int) string   { return strconv.Itoa(v) }
func qs(s string) string  { return "\"" + s + "\"" }

func bools(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func intList(xs []int) string {
	var b strings.Builder
	b.WriteByte('[')
	for i, x := range xs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(itoa(x))
	}
	b.WriteByte(']')
	return b.String()
}

func (t *Table) summaryJSON(b *strings.Builder) {
	b.WriteString("{\"id\":" + strconv.FormatUint(t.ID, 10))
	b.WriteString(",\"smallBlind\":" + i64s(t.SmallBlind))
	b.WriteString(",\"bigBlind\":" + i64s(t.BigBlind))
	b.WriteString(",\"minBuyIn\":" + i64s(t.MinBuyIn))
	b.WriteString(",\"maxBuyIn\":" + i64s(t.MaxBuyIn))
	b.WriteString(",\"maxPlayers\":" + itoa(t.MaxPlayers))
	b.WriteString(",\"actionTimeoutBlocks\":" + strconv.FormatInt(t.ActionTimeout, 10))
	b.WriteString(",\"challengeWindowBlocks\":" + strconv.FormatInt(t.ChallengeWindow, 10))
	b.WriteString(",\"challengeBond\":" + i64s(t.ChallengeBond))
	b.WriteString(",\"button\":" + itoa(t.Button))
	b.WriteString(",\"handNo\":" + strconv.FormatUint(t.HandNo, 10))
	seated := 0
	for _, s := range t.Seats {
		if s != nil {
			seated++
		}
	}
	b.WriteString(",\"seated\":" + itoa(seated))
	phase := ""
	if t.Hand != nil {
		phase = phaseNames[t.Hand.Phase]
	}
	b.WriteString(",\"phase\":" + qs(phase) + "}")
}

// ListTables returns a JSON array of table summaries.
func ListTables() string {
	var b strings.Builder
	b.WriteString("[")
	for i, t := range tables {
		if i > 0 {
			b.WriteString(",")
		}
		t.summaryJSON(&b)
	}
	b.WriteString("]")
	return b.String()
}

// GetTable returns the full table and hand state as JSON.
func GetTable(tableID uint64) string {
	t := getTable(tableID)
	var b strings.Builder
	b.WriteString("{\"id\":" + strconv.FormatUint(t.ID, 10))
	b.WriteString(",\"smallBlind\":" + i64s(t.SmallBlind))
	b.WriteString(",\"bigBlind\":" + i64s(t.BigBlind))
	b.WriteString(",\"minBuyIn\":" + i64s(t.MinBuyIn))
	b.WriteString(",\"maxBuyIn\":" + i64s(t.MaxBuyIn))
	b.WriteString(",\"maxPlayers\":" + itoa(t.MaxPlayers))
	b.WriteString(",\"actionTimeoutBlocks\":" + strconv.FormatInt(t.ActionTimeout, 10))
	b.WriteString(",\"challengeWindowBlocks\":" + strconv.FormatInt(t.ChallengeWindow, 10))
	b.WriteString(",\"challengeBond\":" + i64s(t.ChallengeBond))
	b.WriteString(",\"height\":" + strconv.FormatInt(runtime.ChainHeight(), 10))
	b.WriteString(",\"button\":" + itoa(t.Button))
	b.WriteString(",\"handNo\":" + strconv.FormatUint(t.HandNo, 10))
	b.WriteString(",\"seats\":[")
	for i, s := range t.Seats {
		if i > 0 {
			b.WriteString(",")
		}
		if s == nil {
			b.WriteString("null")
			continue
		}
		b.WriteString("{\"seat\":" + itoa(i))
		b.WriteString(",\"owner\":" + qs(s.Owner.String()))
		b.WriteString(",\"session\":" + qs(s.Session.String()))
		b.WriteString(",\"stack\":" + i64s(s.Stack))
		b.WriteString(",\"sittingOut\":" + bools(s.SittingOut))
		b.WriteString(",\"leaving\":" + bools(s.Leaving))
		b.WriteString(",\"waiting\":" + bools(s.Waiting) + "}")
	}
	b.WriteString("],\"hand\":")
	if t.Hand == nil {
		b.WriteString("null}")
		return b.String()
	}
	t.Hand.writeJSON(&b)
	b.WriteString("}")
	return b.String()
}

func (h *Hand) writeJSON(b *strings.Builder) {
	n := h.n()
	b.WriteString("{\"handNo\":" + strconv.FormatUint(h.No, 10))
	b.WriteString(",\"phase\":" + qs(phaseNames[h.Phase]))
	b.WriteString(",\"players\":[")
	for j, p := range h.Players {
		bp := h.Bet.Players[j]
		if j > 0 {
			b.WriteString(",")
		}
		b.WriteString("{\"seat\":" + itoa(p.Seat))
		b.WriteString(",\"owner\":" + qs(p.Owner.String()))
		b.WriteString(",\"commit\":" + qs(p.Commit))
		b.WriteString(",\"contributed\":" + i64s(bp.Contributed))
		b.WriteString(",\"streetBet\":" + i64s(bp.StreetBet))
		b.WriteString(",\"folded\":" + bools(bp.Folded))
		b.WriteString(",\"allIn\":" + bools(bp.AllIn))
		b.WriteString(",\"acted\":" + bools(bp.Acted))
		canRaise := isBettingPhase(h.Phase) && !bp.Folded && !bp.AllIn && h.Bet.CanRaise(j)
		b.WriteString(",\"canRaise\":" + bools(canRaise))
		b.WriteString(",\"revealed\":" + bools(p.Revealed))
		b.WriteString(",\"accepted\":" + bools(p.Accepted))
		b.WriteString(",\"seed\":" + qs(p.Seed))
		b.WriteString(",\"keys\":{")
		first := true
		for pos := 0; pos < cards.DeckSize; pos++ {
			k, ok := p.Keys[pos]
			if !ok {
				continue
			}
			if !first {
				b.WriteString(",")
			}
			first = false
			b.WriteString(qs(itoa(pos)) + ":" + qs(k))
		}
		b.WriteString("}}")
	}
	b.WriteString("]")
	b.WriteString(",\"turn\":" + itoa(h.turnIndex()))
	owing := []int{}
	if isDealPhase(h.Phase) {
		for j, o := range h.Owing {
			if o {
				owing = append(owing, j)
			}
		}
	} else if h.Phase == phReveal {
		for j, p := range h.Players {
			if !p.Revealed {
				owing = append(owing, j)
			}
		}
	}
	b.WriteString(",\"owing\":" + intList(owing))
	b.WriteString(",\"deadline\":" + strconv.FormatInt(h.Deadline, 10))
	b.WriteString(",\"pot\":" + i64s(h.Bet.Pot()))
	b.WriteString(",\"currentBet\":" + i64s(h.Bet.CurrentBet))
	b.WriteString(",\"minRaise\":" + i64s(h.Bet.MinRaise))
	b.WriteString(",\"deckSeq\":" + itoa(len(h.Roots)))
	b.WriteString(",\"roots\":[")
	for i, r := range h.Roots {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(qs(r))
	}
	b.WriteString("]")
	if h.Cards != nil {
		b.WriteString(",\"board\":" + intList(h.Cards[2*n:2*n+5]))
		b.WriteString(",\"cards\":{")
		for i, c := range h.Cards {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(qs(itoa(i)) + ":" + itoa(c))
		}
		b.WriteString("}")
	} else {
		b.WriteString(",\"board\":[],\"cards\":{}")
	}
	b.WriteString(",\"result\":")
	if h.Result == nil {
		b.WriteString("null}")
		return
	}
	r := h.Result
	b.WriteString("{\"aborted\":" + bools(r.Aborted))
	b.WriteString(",\"convicted\":" + intList(r.Convicted))
	b.WriteString(",\"stallers\":" + intList(r.Stallers))
	b.WriteString(",\"payouts\":{")
	for j, c := range r.Credits {
		if j > 0 {
			b.WriteString(",")
		}
		b.WriteString(qs(itoa(j)) + ":" + i64s(c))
	}
	b.WriteString("},\"hands\":{")
	first := true
	for j, s := range r.Scores {
		if s < 0 {
			continue
		}
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(qs(itoa(j)) + ":" + qs(holdem.CategoryName(s)))
	}
	b.WriteString("},\"challenges\":[")
	for i, c := range r.Challenges {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString("{\"challenger\":" + itoa(c.Challenger) + ",\"accused\":" + itoa(c.Accused) +
			",\"kind\":" + qs(c.Kind) + ",\"index\":" + itoa(c.Index) + ",\"guilty\":" + bools(c.Guilty) + "}")
	}
	b.WriteString("]}}")
}

// GetDeck returns the latest deck pass of the current hand as standard base64,
// or "" before the first pass.
func GetDeck(tableID uint64) string {
	t := getTable(tableID)
	if t.Hand == nil || t.DeckHand != t.HandNo || len(t.Hand.Roots) == 0 {
		return ""
	}
	return cards.EncodeDeck([]byte(t.Deck))
}

// renderMaxTables is the most tables the list page shows.
const renderMaxTables = 50

// Render shows the newest renderMaxTables tables, or one table at path "<id>".
func Render(path string) string {
	if path == "" {
		var b strings.Builder
		b.WriteString("# Poker tables\n\n")
		if len(tables) == 0 {
			b.WriteString("No tables yet.\n")
			return b.String()
		}
		b.WriteString("| Table | Blinds | Buy-in | Seated | Hand | Phase |\n|---|---|---|---|---|---|\n")
		first := 0
		if len(tables) > renderMaxTables {
			first = len(tables) - renderMaxTables
		}
		for k := len(tables) - 1; k >= first; k-- {
			t := tables[k]
			seated := 0
			for i := 0; i < len(t.Seats) && i < maxSeats; i++ {
				if t.Seats[i] != nil {
					seated++
				}
			}
			phase := "-"
			if t.Hand != nil {
				phase = phaseNames[t.Hand.Phase]
			}
			id := strconv.FormatUint(t.ID, 10)
			b.WriteString("| [" + id + "](:" + id + ") | " + strconv.FormatInt(t.SmallBlind, 10) + "/" + strconv.FormatInt(t.BigBlind, 10) +
				" | " + strconv.FormatInt(t.MinBuyIn, 10) + "-" + strconv.FormatInt(t.MaxBuyIn, 10) +
				" | " + itoa(seated) + "/" + itoa(t.MaxPlayers) + " | " + strconv.FormatUint(t.HandNo, 10) + " | " + phase + " |\n")
		}
		if first > 0 {
			b.WriteString("\nShowing the newest " + itoa(renderMaxTables) + " of " + itoa(len(tables)) + " tables. Older tables are at `:<id>`.\n")
		}
		return b.String()
	}
	id, err := strconv.ParseUint(path, 10, 64)
	if err != nil || id == 0 || id > uint64(len(tables)) {
		return "# Not found\n"
	}
	t := tables[id-1]
	var b strings.Builder
	b.WriteString("# Table " + path + "\n\n")
	b.WriteString("Blinds " + strconv.FormatInt(t.SmallBlind, 10) + "/" + strconv.FormatInt(t.BigBlind, 10) + " ugnot, hand " + strconv.FormatUint(t.HandNo, 10) + "\n\n")
	b.WriteString("| Seat | Player | Stack | Status |\n|---|---|---|---|\n")
	for i := 0; i < len(t.Seats) && i < maxSeats; i++ {
		s := t.Seats[i]
		if s == nil {
			b.WriteString("| " + itoa(i) + " | (empty) | | |\n")
			continue
		}
		status := []string{}
		if i == t.Button {
			status = append(status, "button")
		}
		if s.SittingOut {
			status = append(status, "sitting out")
		}
		if s.Leaving {
			status = append(status, "leaving")
		}
		if s.Waiting {
			status = append(status, "waiting")
		}
		b.WriteString("| " + itoa(i) + " | " + s.Owner.String() + " | " + strconv.FormatInt(s.Stack, 10) + " | " + strings.Join(status, ", ") + " |\n")
	}
	h := t.Hand
	if h == nil {
		return b.String()
	}
	n := h.n()
	b.WriteString("\n## Hand " + strconv.FormatUint(h.No, 10) + ": " + phaseNames[h.Phase] + "\n\n")
	b.WriteString("Pot " + strconv.FormatInt(h.Bet.Pot(), 10) + " ugnot, deadline block " + strconv.FormatInt(h.Deadline, 10) + "\n\n")
	if h.Cards != nil {
		board := []string{}
		for k := 0; k < 5; k++ {
			board = append(board, cards.CardString(h.Cards[2*n+k]))
		}
		b.WriteString("Board: " + strings.Join(board, " ") + "\n\n")
	}
	b.WriteString("| # | Seat | Bet | Status | Cards | Result |\n|---|---|---|---|---|---|\n")
	for j := 0; j < n && j < maxSeats; j++ {
		p := h.Players[j]
		bp := h.Bet.Players[j]
		status := ""
		if bp.Folded {
			status = "folded"
		} else if bp.AllIn {
			status = "all-in"
		}
		hole := ""
		if h.Cards != nil {
			hole = cards.CardString(h.Cards[2*j]) + " " + cards.CardString(h.Cards[2*j+1])
		}
		res := ""
		if h.Result != nil && j < len(h.Result.Credits) {
			res = "+" + strconv.FormatInt(h.Result.Credits[j], 10)
		}
		b.WriteString("| " + itoa(j) + " | " + itoa(p.Seat) + " | " + strconv.FormatInt(bp.Contributed, 10) + " | " + status + " | " + hole + " | " + res + " |\n")
	}
	return b.String()
}
