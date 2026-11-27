package hall

import (
	"chain"
	"chain/runtime"
	"strconv"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
)

// Solve is one claimed capture.
type Solve struct {
	Player     address
	Slug       string
	Height     int64
	Season     int
	FirstBlood bool
}

// Claim records that the caller broke the challenge slug and returns the
// points it is now worth. The challenge realm is asked whether the player
// captured it; the hall never takes the player's word for it.
//
// Call it from your wallet, or from your solution realm right after the
// exploit: a realm at gno.land/r/<your-address>/... is credited to you.
func Claim(cur realm, slug string) int {
	player := flag.MustPlayer(cur.Previous())
	e := mustEntry(slug)
	if e.status != Listed {
		panic(ErrNotListed)
	}
	p := profileOf(player)
	if p.solved(slug) {
		panic(ErrAlreadyClaimed)
	}
	if !e.ch.Captured(player) {
		panic(ErrNotCaptured)
	}

	s := Solve{
		Player:     player,
		Slug:       slug,
		Height:     runtime.ChainHeight(),
		Season:     currentSeason().Number,
		FirstBlood: len(e.solvers) == 0,
	}
	e.solvers = append(e.solvers, player)
	p.solves = append(p.solves, s)
	currentSeason().Claims++
	pushFeed(s)
	awardSolve(p, s)

	chain.Emit("Claimed",
		"slug", slug,
		"player", player.String(),
		"firstBlood", strconv.FormatBool(s.FirstBlood),
		"season", strconv.Itoa(s.Season),
	)
	return e.value()
}

func pushFeed(s Solve) {
	feed = append(feed, s)
	if len(feed) > feedSize {
		feed = feed[len(feed)-feedSize:]
	}
}

// solvePoints is what one solve is worth today, first blood included.
func solvePoints(s Solve) int {
	e, ok := getEntry(s.Slug)
	if !ok {
		return 0
	}
	pts := e.value()
	if s.FirstBlood {
		pts += e.info.Difficulty.FirstBloodBonus()
	}
	return pts
}
