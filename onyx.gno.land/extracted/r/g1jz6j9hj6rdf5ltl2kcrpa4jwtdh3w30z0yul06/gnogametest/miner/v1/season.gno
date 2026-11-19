package miner

import (
	"chain"
	"strconv"

	"gno.land/p/nt/avl/v0"

	eco "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/gnogame/miner/v1"
)

// Seasons and badges on chain
//
// A season's result for a player is their projection for it (see the
// package comment): the farm's season value, rounded, if the player does
// nothing more. Each season keeps an eco.Ladder of its players' results:
//
//   - N: results of at least Copper (100,000), so accounts that only join
//     cannot create rank slots.
//   - Sapphire and Diamond go only to results of at least Pearl
//     (3,300,000); below it the fixed thresholds Copper … Pearl apply.
//   - Diamond: every result at or above the Diamond cutoff, the lowest
//     result at which no more than ceil(2%·N) results are at or above it.
//     Sapphire: the rest down to the Sapphire cutoff, the lowest result at
//     which no more than ceil(5%·N) are (Diamond included). Equal results
//     get the same badge; at most 2% (5%) of N ever qualify.
//
// The ladder moves with the projections while the season runs, so its
// badges are "if the season ended now". At the season end the projections
// are final, and so are the cutoffs. The first Join or Collect (by anyone)
// after the season ended stores them in the season record (event
// SeasonFinal); until then they are computed on every read (a walk of at
// most ceil(5%·N)+1 histogram entries). A player's history entry gets the
// final badge when their farm rolls over (event SeasonEnd).

var (
	seasons avl.Tree // seasonKey(n) -> *seasonRec

	copperMin = eco.Badges[eco.CopperIdx].Min
	pearlMin  = eco.Badges[eco.PearlIdx].Min
)

// seasonRec is one season's results: no per-player entry.
type seasonRec struct {
	ladder eco.Ladder
	final  bool     // cuts are stored (the season has ended)
	cuts   eco.Cuts // valid when final
}

func pad15(x int64) string {
	s := strconv.FormatInt(x, 10)
	return "000000000000000"[len(s):] + s
}

func seasonKey(n int) string { return pad15(int64(n)) }

func recOf(n int) *seasonRec {
	v := seasons.Get(seasonKey(n))
	if v == nil {
		return nil
	}
	return v.(*seasonRec)
}

func rec(n int) *seasonRec {
	r := recOf(n)
	if r == nil {
		r = &seasonRec{}
		seasons.Set(seasonKey(n), r)
	}
	return r
}

// badgeName of a badge index, "" for none (-1).
func badgeName(i int) string {
	if i < 0 {
		return ""
	}
	return eco.Badges[i].Name
}

// project: the farm's projected season result, rounded. It settles st up
// to the season end (Settle stops at the monitoring window), so st must not
// be used afterwards.
func project(st *eco.State) int64 {
	st.Settle(st.SeasonEnd())
	v := eco.JSRound(st.Value)
	if v < 0 {
		return 0
	}
	return int64(v)
}

// save stores the farm and its projection. entered: the farm has just
// entered season st.Season (Join or rollover); otherwise its projection
// moves within that season's ladder. Only called before the farm's season
// ends, so an ended season's ladder never changes. st is spent afterwards.
func save(p *player, st *eco.State, entered bool) {
	p.farm = eco.Encode(st)
	v := project(st)
	r := rec(st.Season)
	if entered {
		r.ladder.Add(v)
	} else {
		r.ladder.Move(p.proj, v)
	}
	p.proj = v
	p.season = st.Season
}

// cutsOf: season n's cutoffs, stored ones if final, else as of now.
func cutsOf(n int) eco.Cuts {
	r := recOf(n)
	if r == nil {
		return eco.Cuts{}
	}
	if r.final {
		return r.cuts
	}
	return r.ladder.Cuts()
}

// finalCuts stores the cutoffs of season n, which has ended, unless that is
// done already, and returns them.
func finalCuts(n int) eco.Cuts {
	r := recOf(n)
	if r == nil {
		return eco.Cuts{}
	}
	if !r.final {
		r.cuts = r.ladder.Cuts()
		r.final = true
		chain.Emit("SeasonFinal",
			"season", strconv.Itoa(n),
			"players", strconv.Itoa(r.ladder.Players),
			"counted", strconv.Itoa(r.ladder.Counted),
			"diamond", strconv.Itoa(r.cuts.NDiamond),
			"sapphire", strconv.Itoa(r.cuts.NSapphire),
			"diamondCutoff", strconv.FormatInt(r.cuts.Diamond, 10),
			"sapphireCutoff", strconv.FormatInt(r.cuts.Sapphire, 10))
	}
	return r.cuts
}

// cacheLast: run at the end of every Join and Collect in season n; stores
// the previous season's cutoffs the first time.
func cacheLast(n int) {
	if n > 1 {
		finalCuts(n - 1)
	}
}

// rollover ends the farm's season (over at block time t) and returns the
// farm's start state in season n at t. The result is the stored
// projection: the farm cannot have changed since it was computed, and
// settling it to the season end (done here, for the history entry's
// "mined") gives the same value. The badge is the final rank badge; the
// next season starts with that badge's cards. The farm is no newcomer
// there (Born = season start) and mines nothing for the time away.
func rollover(key string, p *player, st *eco.State, n int, t int64) *eco.State {
	f := p.season
	b := eco.RankBadge(p.proj, finalCuts(f))
	next := st.NewSeason(st.SeasonEnd(), "")
	h := &next.History[len(next.History)-1]
	h.Value = float64(p.proj)
	h.Badge = badgeName(b)
	cards := []int{1}
	if b >= 0 {
		cards = eco.Badges[b].Start
	}
	next.Cards = map[int]*eco.Card{}
	next.Rigs = [][]int{{0, 0, 0, 0}} // as eco.NewSeason
	for k, ty := range cards {
		next.Cards[k+1] = &eco.Card{T: ty}
		next.Rigs[0][k] = k + 1
	}
	next.NextID = len(cards) + 1
	ss := seasonStartOf(n)
	next.Season = n
	next.SeasonStart = ss
	next.Born = ss
	next.Last = t
	next.LastClaim = t
	chain.Emit("SeasonEnd",
		"player", key,
		"season", strconv.Itoa(f),
		"value", strconv.FormatInt(p.proj, 10),
		"badge", h.Badge)
	return next
}

// PlayerSeason returns the player's latest season result as JSON:
// {"season","projection","badge","final","players","ahead","tied"}.
// season: the season of the
// farm's last Join or Collect; projection: its projected result, the final
// result once the season has ended; badge: the badge of that result under
// the rank rule ("" for none) — the final badge when final is true (the
// season has ended), else the badge "if the season ended now"; players:
// farms with a result for that season; ahead and tied: the player's place
// among them (eco.Ladder.Place: exact at or above Pearl, the badge band
// below it). "" for an address that has not joined.
func PlayerSeason(addr address) string {
	v := players.Get(addr.String())
	if v == nil {
		return ""
	}
	p := v.(*player)
	fin := ended(p.season, now())
	pl, ahead, tied := 0, 0, 0
	if r := recOf(p.season); r != nil {
		pl = r.ladder.Players
		ahead, tied = r.ladder.Place(p.proj)
	}
	return `{"season":` + strconv.Itoa(p.season) +
		`,"projection":` + strconv.FormatInt(p.proj, 10) +
		`,"badge":` + jsonStr(badgeName(eco.RankBadge(p.proj, cutsOf(p.season)))) +
		`,"final":` + strconv.FormatBool(fin) +
		`,"players":` + strconv.Itoa(pl) +
		`,"ahead":` + strconv.Itoa(ahead) +
		`,"tied":` + strconv.Itoa(tied) + `}`
}

// SeasonResult returns season n's results as JSON: {"season","ended",
// "players","counted","pearlPlus","diamondCutoff","sapphireCutoff",
// "diamond","sapphire"}. ended: the results are final; players: farms with
// a result for the season; counted: N of the rank rule (results of at
// least Copper); pearlPlus: results of at least Pearl; the cutoffs are the
// lowest result that gets Diamond / Sapphire (0: nobody), diamond and
// sapphire how many players get them. Before the season ends these are
// "if the season ended now". n must be at least 1; a season that has not
// started yet has no results.
func SeasonResult(n int) string {
	if n < 1 {
		panic("no such season")
	}
	pl, cnt, pp := 0, 0, 0
	var c eco.Cuts
	if r := recOf(n); r != nil {
		pl, cnt, pp = r.ladder.Players, r.ladder.Counted, r.ladder.PearlPlus
		c = cutsOf(n)
	}
	return `{"season":` + strconv.Itoa(n) +
		`,"ended":` + strconv.FormatBool(ended(n, now())) +
		`,"players":` + strconv.Itoa(pl) +
		`,"counted":` + strconv.Itoa(cnt) +
		`,"pearlPlus":` + strconv.Itoa(pp) +
		`,"diamondCutoff":` + strconv.FormatInt(c.Diamond, 10) +
		`,"sapphireCutoff":` + strconv.FormatInt(c.Sapphire, 10) +
		`,"diamond":` + strconv.Itoa(c.NDiamond) +
		`,"sapphire":` + strconv.Itoa(c.NSapphire) + `}`
}
