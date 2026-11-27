package arena

import (
	"strconv"
	"strings"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/game"
)

// Read API for apps and tools. Every function returns JSON and changes
// nothing, so it can be called for free with a vm/qeval query, e.g.
//
//	gnokey query vm/qeval -data 'gno.land/r/<ns>/arena.BotsJSON()'

func jsonString(s string) string {
	var sb strings.Builder
	sb.WriteByte('"')
	for _, c := range s {
		switch {
		case c == '"':
			sb.WriteString(`\"`)
		case c == '\\':
			sb.WriteString(`\\`)
		case c < 0x20:
			sb.WriteString(`\u00`)
			sb.WriteByte("0123456789abcdef"[c>>4])
			sb.WriteByte("0123456789abcdef"[c&0xf])
		default:
			sb.WriteRune(c)
		}
	}
	sb.WriteByte('"')
	return sb.String()
}

type jsonObj struct{ parts []string }

func (o *jsonObj) str(k, v string) *jsonObj {
	o.parts = append(o.parts, jsonString(k)+":"+jsonString(v))
	return o
}
func (o *jsonObj) num(k string, v int) *jsonObj {
	o.parts = append(o.parts, jsonString(k)+":"+strconv.Itoa(v))
	return o
}
func (o *jsonObj) num64(k string, v int64) *jsonObj {
	o.parts = append(o.parts, jsonString(k)+":"+strconv.FormatInt(v, 10))
	return o
}
func (o *jsonObj) flag(k string, v bool) *jsonObj {
	o.parts = append(o.parts, jsonString(k)+":"+strconv.FormatBool(v))
	return o
}
func (o *jsonObj) raw(k, v string) *jsonObj {
	o.parts = append(o.parts, jsonString(k)+":"+v)
	return o
}
func (o *jsonObj) String() string { return "{" + strings.Join(o.parts, ",") + "}" }

func jsonArray(items []string) string { return "[" + strings.Join(items, ",") + "]" }

func posJSON(p bot.Pos) string { return "[" + strconv.Itoa(p.X) + "," + strconv.Itoa(p.Y) + "]" }

func botJSON(b *Bot) string {
	o := &jsonObj{}
	o.str("name", b.Name).str("realm", b.Realm).str("owner", b.Owner.String()).
		str("kind", b.kind()).str("description", b.Description).
		num("version", b.Version).flag("retired", b.Retired).
		num("rating", b.Rating).
		num("seasonWins", b.SeasonWins).num("seasonLosses", b.SeasonLosses).num("seasonDraws", b.SeasonDraws).
		num("wins", b.Wins).num("losses", b.Losses).num("draws", b.Draws).num("forfeits", b.Forfeits).
		num64("registered", b.Registered)
	return o.String()
}

// ArenaJSON returns counts, the current season and the block height.
func ArenaJSON() string {
	n, end := SeasonInfo()
	o := &jsonObj{}
	o.num("bots", bots.Size()).num("matches", lastID).num("tournaments", lastTID).
		num("season", n).num64("seasonStart", seasonStart).num64("seasonEnds", end).
		num64("height", height()).num("seasonLength", SeasonLength).
		num("moveTimeout", MoveTimeout).num("ratedCooldown", RatedCooldown).
		num("boardSize", bot.Size).num("turns", bot.Turns)
	return o.String()
}

// BotsJSON returns every bot, ranked like the leaderboard.
func BotsJSON() string {
	var items []string
	for _, b := range leaderboard() {
		items = append(items, botJSON(b))
	}
	return jsonArray(items)
}

// BotJSON returns one bot, with its earlier versions.
func BotJSON(name string) string {
	b := mustBot(name)
	var prev []string
	for _, r := range b.PreviousVersions() {
		prev = append(prev, jsonString(r))
	}
	return strings.TrimSuffix(botJSON(b), "}") + `,"previousVersions":` + jsonArray(prev) + "}"
}

func matchSummaryJSON(m *Match) string {
	o := &jsonObj{}
	o.num("id", m.ID).str("a", m.BotA).str("b", m.BotB).
		str("status", m.Status.String()).num("turn", m.Game.Turn).
		num("goldA", m.Game.GoldA).num("goldB", m.Game.GoldB).
		num("winner", m.Winner).flag("forfeit", m.Forfeit).str("reason", m.Reason).
		flag("rated", m.Rated).num("delta", m.Delta).
		num("season", m.Season).num("tournament", m.Tournament).
		num64("created", m.Created).num64("settled", m.Settled).
		str("summary", m.Summary())
	if m.Status == Stepping {
		o.str("waitingFor", m.Bot(m.Waiting)).num64("deadline", m.Deadline)
	}
	return o.String()
}

// MatchesJSON returns up to limit matches, newest first, optionally only
// those of one bot (looking at no more than the last 500).
func MatchesJSON(botName string, limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	var items []string
	eachRecent(500, func(m *Match) bool {
		if botName != "" && m.BotA != botName && m.BotB != botName {
			return false
		}
		items = append(items, matchSummaryJSON(m))
		return len(items) >= limit
	})
	return jsonArray(items)
}

// MatchJSON returns a match with every turn, for replays: positions, gold
// and coins after each turn, both actions and what happened.
func MatchJSON(id int) string {
	m := mustMatch(id)
	r := game.New(m.Game.Seed)
	frames := []string{frameJSON(r, [2]bot.Action{}, game.Events{})}
	g := &m.Game
	for i := 0; i < g.Turn; i++ {
		acts := [2]bot.Action{bot.Action(g.Moves[2*i]), bot.Action(g.Moves[2*i+1])}
		ev := r.Step(acts[0], acts[1])
		frames = append(frames, frameJSON(r, acts, ev))
	}
	return strings.TrimSuffix(matchSummaryJSON(m), "}") + `,"seed":` + strconv.Itoa(g.Seed) + `,"frames":` + jsonArray(frames) + "}"
}

func frameJSON(g *game.Game, acts [2]bot.Action, ev game.Events) string {
	var coins []string
	for _, c := range g.CoinList() {
		coins = append(coins, posJSON(c))
	}
	o := &jsonObj{}
	o.num("turn", g.Turn).
		raw("pos", "["+posJSON(g.Pos(0))+","+posJSON(g.Pos(1))+"]").
		raw("gold", "["+strconv.Itoa(g.GoldA)+","+strconv.Itoa(g.GoldB)+"]").
		raw("actions", "["+jsonString(acts[0].String())+","+jsonString(acts[1].String())+"]").
		raw("stole", "["+strconv.FormatBool(ev.Stole[0])+","+strconv.FormatBool(ev.Stole[1])+"]").
		raw("parried", "["+strconv.FormatBool(ev.Parried[0])+","+strconv.FormatBool(ev.Parried[1])+"]").
		num("spawned", ev.Spawned).
		raw("coins", jsonArray(coins))
	return o.String()
}

func tournamentJSON(t *Tournament, full bool) string {
	o := &jsonObj{}
	var entrants []string
	for _, e := range t.Entrants {
		entrants = append(entrants, jsonString(e))
	}
	o.num("id", t.ID).str("name", t.Name).str("creator", t.Creator.String()).
		num64("created", t.Created).num("capacity", t.Capacity).
		str("status", t.Status.String()).str("winner", t.Winner).
		raw("entrants", jsonArray(entrants))
	if !full {
		return o.String()
	}
	var table []string
	for _, r := range t.Standings() {
		row := &jsonObj{}
		row.str("bot", r.Bot).num("played", r.Played).num("wins", r.Wins).num("draws", r.Draws).
			num("losses", r.Losses).num("goldFor", r.GoldFor).num("goldAgainst", r.GoldAgainst).num("points", r.Points)
		table = append(table, row.String())
	}
	var sched []string
	for i, p := range t.Pairs {
		ab := strings.Split(p, "|")
		row := &jsonObj{}
		row.str("a", ab[0]).str("b", ab[1]).num("match", t.MatchIDs[i])
		sched = append(sched, row.String())
	}
	o.raw("table", jsonArray(table)).raw("schedule", jsonArray(sched))
	return o.String()
}

// TournamentsJSON returns every tournament, newest first.
func TournamentsJSON() string {
	var items []string
	tournaments.ReverseIterate("", "", func(_ string, v any) bool {
		items = append(items, tournamentJSON(v.(*Tournament), false))
		return false
	})
	return jsonArray(items)
}

// TournamentJSON returns one tournament with its table and schedule.
func TournamentJSON(id int) string { return tournamentJSON(mustTournament(id), true) }

// SeasonsJSON returns the top 10 of every finished season, newest first.
func SeasonsJSON() string {
	var items []string
	for n := season - 1; n >= 1; n-- {
		var rows []string
		for _, s := range PastSeason(n) {
			row := &jsonObj{}
			row.str("bot", s.Bot).num("rating", s.Rating).num("wins", s.Wins).num("losses", s.Losses).num("draws", s.Draws)
			rows = append(rows, row.String())
		}
		o := &jsonObj{}
		o.num("season", n).raw("top", jsonArray(rows))
		items = append(items, o.String())
	}
	return jsonArray(items)
}
