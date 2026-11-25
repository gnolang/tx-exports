package taproom

// Leaderboards: net coins, sharpest guesses, longest streak, points and style. Stats are kept on
// each Player, and each board is a sorted index (an avl tree) updated whenever a listed stat moves,
// so reading the top rows costs the same however many players there are.

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	maxBoardRows = 50
	boardCount   = 5
)

// boards in display order: key, title, column heading.
var boards = [boardCount][3]string{
	{"points", "Points", "Lifetime points"},
	{"net", "Net coins", "Net GNOT"},
	{"sharp", "Sharpest guesses", "Avg distance"},
	{"streak", "Longest streak", "Weeks"},
	{"style", "Style", "Style score"},
}

type boardRow struct {
	addr address
	p    *Player
}

// styleOf sums rarity values of equipped items: common 1, rare 3, epic 6, legendary 10.
func styleOf(equipped [4]int) int64 {
	var s int64
	for _, id := range equipped {
		switch itemPrice(id) {
		case 40:
			s += 1
		case 150:
			s += 3
		case 400:
			s += 6
		case 1000:
			s += 10
		}
	}
	return s
}

// sharp100 is the average distance to the target in hundredths; -1 before any completed round.
func sharp100(p *Player) int64 {
	if p.Scored == 0 {
		return -1
	}
	return p.DistSum100 / p.Scored
}

// boardIdx holds one sorted index per board: boardKey -> address.
var boardIdx = newBoardIdx()

func newBoardIdx() [boardCount]*avl.Tree {
	var t [boardCount]*avl.Tree
	for i := range t {
		t[i] = avl.NewTree()
	}
	return t
}

// boardKey orders a player on board i, best first; ties go by address. ok is false when the
// player is not listed: before their first Join, or on Sharpest guesses before a completed round.
func boardKey(i int, a address, p *Player) (key string, ok bool) {
	if !p.Joined {
		return "", false
	}
	var v int64
	lowerIsBetter := false
	switch boards[i][0] {
	case "points":
		v = p.Lifetime
	case "net":
		v = p.Net
	case "sharp":
		if p.Scored == 0 {
			return "", false
		}
		v, lowerIsBetter = sharp100(p), true
	case "streak":
		v = p.BestStreak
	case "style":
		v = styleOf(p.Equipped)
	}
	k := uint64(v) ^ (1 << 63) // signed order as unsigned order
	if !lowerIsBetter {
		k = ^k
	}
	h := strconv.FormatUint(k, 16)
	for len(h) < 16 {
		h = "0" + h
	}
	return h + ":" + a.String(), true
}

// reindex moves a player's rows in the board indexes after their stats change.
func reindex(a address) {
	p := getPlayer(a)
	for i := 0; i < boardCount; i++ {
		k, ok := boardKey(i, a, p)
		if k == p.boardKeys[i] {
			continue
		}
		if p.boardKeys[i] != "" {
			boardIdx[i].Remove(p.boardKeys[i])
		}
		if ok {
			boardIdx[i].Set(k, a)
		}
		p.boardKeys[i] = k
	}
}

// board returns the top rows of a board, best first.
func board(name string, limit int) []boardRow {
	idx := -1
	for i, b := range boards {
		if b[0] == name {
			idx = i
		}
	}
	if idx < 0 {
		panic("unknown board: use points, net, sharp, streak or style")
	}
	if limit <= 0 || limit > maxBoardRows {
		limit = maxBoardRows
	}
	var rows []boardRow
	boardIdx[idx].Iterate("", "", func(_ string, v any) bool {
		a := v.(address)
		rows = append(rows, boardRow{addr: a, p: players.Get(a.String()).(*Player)})
		return len(rows) >= limit
	})
	return rows
}

// LeaderboardJSON returns the top rows (at most 50) of a board: points, net, sharp, streak or style.
// Each row carries every stat, so one call can fill any column.
func LeaderboardJSON(name string, limit int) string {
	var sb strings.Builder
	sb.WriteString("[")
	for i, r := range board(name, limit) {
		if i > 0 {
			sb.WriteString(",")
		}
		sharp := "null"
		if s := sharp100(r.p); s >= 0 {
			sharp = i64(s)
		}
		sb.WriteString(`{"rank":` + strconv.Itoa(i+1) + `,"addr":"` + r.addr.String() + `","points":` + i64(r.p.Lifetime))
		sb.WriteString(`,"net":` + i64(r.p.Net) + `,"wins":` + i64(r.p.Wins) + `,"sharp100":` + sharp)
		sb.WriteString(`,"bestStreak":` + i64(r.p.BestStreak) + `,"style":` + i64(styleOf(r.p.Equipped)) + `,"equipped":`)
		writeInts(&sb, r.p.Equipped[:])
		sb.WriteString("}")
	}
	sb.WriteString("]")
	return sb.String()
}
