package taproom

// Leaderboards: net coins, sharpest guesses, longest streak, points and style. Stats are kept on
// each Player, and each board is a short sorted list of its top rows (boardTop), updated whenever
// a listed stat moves.

import (
	"strconv"
	"strings"
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

// boardRank is one row of a board's top list: the player and the value they are ranked by.
type boardRank struct {
	Addr address
	V    int64
}

// boardTop holds each board's top maxBoardRows rows, best first. A short list instead of an index
// over every player: an update rewrites one list, which stops growing once it is full, so a
// player's first join adds little storage however many players there are. A listed player whose
// value drops out of the top rows leaves the list; a player just below returns when their own
// stats next change, so the rows near the bottom can lag until then.
var boardTop [boardCount][]boardRank

// boardValue is what a player is ranked by on board i. ok is false when the player is not listed:
// before their first Join, or on Sharpest guesses before a completed round.
func boardValue(i int, p *Player) (v int64, ok bool) {
	if !p.Joined {
		return 0, false
	}
	switch boards[i][0] {
	case "points":
		return p.Lifetime, true
	case "net":
		return p.Net, true
	case "sharp":
		if p.Scored == 0 {
			return 0, false
		}
		return sharp100(p), true
	case "streak":
		return p.BestStreak, true
	}
	return styleOf(p.Equipped), true
}

// ahead reports whether row x ranks above row y on board i: a better value (lower is better only
// for Sharpest guesses), then the lower address.
func ahead(i int, x, y boardRank) bool {
	if x.V != y.V {
		if boards[i][0] == "sharp" {
			return x.V < y.V
		}
		return x.V > y.V
	}
	return x.Addr < y.Addr
}

// reindex moves a player's rows on the boards after their stats change.
func reindex(a address) {
	p := getPlayer(a)
	for i := 0; i < boardCount; i++ {
		v, ok := boardValue(i, p)
		list := boardTop[i]
		pos := -1
		for j, r := range list {
			if r.Addr == a {
				pos = j
				break
			}
		}
		if pos >= 0 && ok && list[pos].V == v {
			continue // already listed at this value
		}
		changed := false
		if pos >= 0 {
			list = append(list[:pos], list[pos+1:]...)
			changed = true
		}
		if ok {
			row := boardRank{Addr: a, V: v}
			j := 0
			for j < len(list) && ahead(i, list[j], row) {
				j++
			}
			if j < maxBoardRows {
				list = append(list, boardRank{})
				copy(list[j+1:], list[j:])
				list[j] = row
				if len(list) > maxBoardRows {
					list = list[:maxBoardRows]
				}
				changed = true
			}
		}
		if changed {
			boardTop[i] = list
		}
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
	for _, r := range boardTop[idx] {
		if len(rows) >= limit {
			break
		}
		rows = append(rows, boardRow{addr: r.Addr, p: players.Get(r.Addr.String()).(*Player)})
	}
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
