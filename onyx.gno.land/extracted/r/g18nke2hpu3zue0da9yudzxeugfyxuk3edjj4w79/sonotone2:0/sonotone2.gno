// Gno realm (smart contract) for Sonotone — version 2.
// Two separate leaderboards: "classic" and "melomane".
// Mélomane mode unlocks at 135 points in Classic, and the contract
// itself enforces it (no cheating by tweaking the browser).

package sonotone2

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	MaxScore         = 1000000
	MelomaneUnlockAt = 135 // Classic points needed to unlock Mélomane
)

// Record = best result in one mode.
type Record struct {
	Score      int
	Level      int
	Instrument string
}

// Player = a registered player and their best record per mode.
type Player struct {
	Pseudo   string
	Address  address
	Classic  Record
	Melomane Record
}

var (
	players avl.Tree // key: wallet address -> *Player
	pseudos avl.Tree // key: lowercase nickname -> wallet address
)

// ---------------------------------------------------------------------
// Functions called by players (transactions signed with Adena)
// ---------------------------------------------------------------------

// Register links a nickname to the wallet signing the transaction.
func Register(cur realm, pseudo string) {
	caller := cur.Previous()
	if !caller.IsUser() {
		panic("only a wallet can register")
	}
	key := caller.Address().String()

	if players.Has(key) {
		panic("this wallet already has a nickname")
	}
	checkPseudo(pseudo)

	lower := strings.ToLower(pseudo)
	if pseudos.Has(lower) {
		panic("this nickname is already taken")
	}

	players.Set(key, &Player{
		Pseudo:  pseudo,
		Address: caller.Address(),
	})
	pseudos.Set(lower, key)
}

// SubmitScore saves a new record in a mode ("classic" or "melomane").
func SubmitScore(cur realm, mode string, score int, level int, instrument string) {
	key := cur.Previous().Address().String()

	v := players.Get(key)
	if v == nil {
		panic("register a nickname first")
	}
	if score <= 0 || score > MaxScore {
		panic("invalid score")
	}
	if level < 1 || level > 1000 {
		panic("invalid level")
	}
	if !validInstrument(instrument) {
		panic("unknown instrument")
	}

	p := v.(*Player)
	switch mode {
	case "classic":
		if score <= p.Classic.Score {
			panic("not a new record")
		}
		p.Classic = Record{Score: score, Level: level, Instrument: instrument}
	case "melomane":
		if p.Classic.Score < MelomaneUnlockAt {
			panic("Mélomane mode locked: score 135 points in Classic first")
		}
		if score <= p.Melomane.Score {
			panic("not a new record")
		}
		p.Melomane = Record{Score: score, Level: level, Instrument: instrument}
	default:
		panic("unknown mode")
	}
}

// ---------------------------------------------------------------------
// Read-only functions (free, used by the game)
// ---------------------------------------------------------------------

// GetPlayerJSON returns an address's full profile as JSON, or "null":
// {"pseudo":"…","address":"…","melomane_unlocked":true,
//  "classic":{"score":…,"level_max":…,"instrument":"…"},
//  "melomane":{"score":…,"level_max":…,"instrument":"…"}}
func GetPlayerJSON(addr string) string {
	v := players.Get(addr)
	if v == nil {
		return "null"
	}
	p := v.(*Player)
	unlocked := "false"
	if p.Classic.Score >= MelomaneUnlockAt {
		unlocked = "true"
	}
	return `{"pseudo":"` + p.Pseudo +
		`","address":"` + p.Address.String() +
		`","melomane_unlocked":` + unlocked +
		`,"classic":` + recordJSON(p.Classic) +
		`,"melomane":` + recordJSON(p.Melomane) + `}`
}

// GetTopJSON returns the top n players of a mode, as JSON:
// [{"pseudo":"…","address":"…","score":…,"level_max":…,"instrument":"…"}, …]
func GetTopJSON(mode string, n int) string {
	top := topPlayers(mode, n)
	out := "["
	for i, p := range top {
		if i > 0 {
			out += ","
		}
		r := recordOf(p, mode)
		out += `{"pseudo":"` + p.Pseudo +
			`","address":"` + p.Address.String() +
			`","score":` + strconv.Itoa(r.Score) +
			`,"level_max":` + strconv.Itoa(r.Level) +
			`,"instrument":"` + r.Instrument + `"}`
	}
	return out + "]"
}

// Render shows both leaderboards as Markdown on gnoweb.
func Render(_ string) string {
	out := "# 🎧 Sonotone — Leaderboards\n\n"
	out += renderTable("🎵 Classic", "classic")
	out += renderTable("𝄞 Mélomane", "melomane")
	return out
}

// ---------------------------------------------------------------------
// Internal functions
// ---------------------------------------------------------------------

func renderTable(title, mode string) string {
	out := "## " + title + "\n\n"
	top := topPlayers(mode, 20)
	if len(top) == 0 {
		return out + "No scores yet.\n\n"
	}
	out += "| # | Nickname | Score | Level | Instrument |\n"
	out += "|---|--------|-------|--------|------------|\n"
	for i, p := range top {
		r := recordOf(p, mode)
		out += "| " + strconv.Itoa(i+1) +
			" | " + p.Pseudo +
			" | " + strconv.Itoa(r.Score) +
			" | " + strconv.Itoa(r.Level) +
			" | " + r.Instrument + " |\n"
	}
	return out + "\n"
}

func recordOf(p *Player, mode string) Record {
	if mode == "melomane" {
		return p.Melomane
	}
	return p.Classic
}

func recordJSON(r Record) string {
	return `{"score":` + strconv.Itoa(r.Score) +
		`,"level_max":` + strconv.Itoa(r.Level) +
		`,"instrument":"` + r.Instrument + `"}`
}

// checkPseudo: 3 to 20 characters, letters, digits, _ and - only.
func checkPseudo(p string) {
	if len(p) < 3 || len(p) > 20 {
		panic("nickname must be 3 to 20 characters")
	}
	for _, c := range p {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok {
			panic("nickname: only letters (no accents), digits, _ and -")
		}
	}
}

func validInstrument(i string) bool {
	return i == "piano" || i == "bass" || i == "guitar" || i == "organ"
}

// topPlayers sorts players with a score in this mode, highest first.
func topPlayers(mode string, n int) []*Player {
	var list []*Player
	players.Iterate("", "", func(_ string, value any) bool {
		p := value.(*Player)
		if recordOf(p, mode).Score > 0 {
			list = append(list, p)
		}
		return false
	})

	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && recordOf(list[j], mode).Score > recordOf(list[j-1], mode).Score; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}

	if n > 0 && len(list) > n {
		list = list[:n]
	}
	return list
}
