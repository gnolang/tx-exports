package hall

import (
	"chain"
	"chain/runtime"
	"strconv"
)

// podiumSize is how many players a closing season decorates.
const podiumSize = 3

// season is a stretch of play with its own standings. New challenges
// usually open with a new season.
type season struct {
	Number   int
	Name     string
	OpenedAt int64
	ClosedAt int64 // 0 while open
	Claims   int
	Podium   []address
}

func newSeason(n int, name string) *season {
	return &season{Number: n, Name: name, OpenedAt: runtime.ChainHeight()}
}

func currentSeason() *season { return seasons[len(seasons)-1] }

// OpenSeason closes the current season, decorates its podium with season
// badges, and opens the next one under name.
func OpenSeason(cur realm, name string) {
	assertCurator(cur)
	if len(name) == 0 || len(name) > 40 {
		panic(ErrBadSeasonName)
	}
	closing := currentSeason()
	closing.ClosedAt = runtime.ChainHeight()
	for i, row := range standings(closing.Number) {
		if i == podiumSize {
			break
		}
		closing.Podium = append(closing.Podium, row.Player)
		awardSeason(row.Player, closing.Number, i+1)
	}
	next := newSeason(closing.Number+1, name)
	seasons = append(seasons, next)
	chain.Emit("SeasonOpened", "number", strconv.Itoa(next.Number), "name", name)
}
