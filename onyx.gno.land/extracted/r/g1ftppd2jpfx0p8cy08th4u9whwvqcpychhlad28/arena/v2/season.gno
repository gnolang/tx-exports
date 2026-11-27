package arena

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Seasons. Ratings and season records reset every SeasonLength blocks, and
// each finished season's top 10 is kept. The switch happens lazily: the first
// match or challenge after a season's end closes it, so no scheduler is
// needed. All-time records (Wins, Losses, Draws) never reset.

// SeasonLength is about 30 days at Onyx's ~3.6 s blocks.
const SeasonLength = 720000

var (
	season      = 1
	seasonStart = int64(0)           // set on the first activity
	pastSeasons = avl.NewTree()      // padded season number -> "name:rating:w-l-d," top 10
	seasonTop   = 10
)

// SeasonInfo reports the current season number and the block it ends at.
func SeasonInfo() (number int, endsAt int64) {
	return season, seasonStart + SeasonLength
}

// rollSeason closes the current season if it is over. Call it before any
// state change that touches ratings.
func rollSeason() {
	now := height()
	if seasonStart == 0 {
		seasonStart = now
		return
	}
	for now >= seasonStart+SeasonLength {
		closeSeason()
		seasonStart += SeasonLength
	}
}

func closeSeason() {
	var sb strings.Builder
	for i, b := range leaderboard() {
		if i == seasonTop {
			break
		}
		if b.SeasonWins+b.SeasonLosses+b.SeasonDraws == 0 {
			continue // didn't play this season
		}
		sb.WriteString(ufmt.Sprintf("%s:%d:%d-%d-%d,", b.Name, b.Rating, b.SeasonWins, b.SeasonLosses, b.SeasonDraws))
	}
	pastSeasons.Set(key(season), sb.String())
	emit("SeasonEnded", "season", strconv.Itoa(season))
	bots.Iterate("", "", func(_ string, v any) bool {
		b := v.(*Bot)
		b.Rating = startRating
		b.SeasonWins, b.SeasonLosses, b.SeasonDraws = 0, 0, 0
		b.recentRated = ""
		return false
	})
	season++
}

// SeasonStanding is one line of a finished season's top 10.
type SeasonStanding struct {
	Bot             string
	Rating          int
	Wins, Losses, Draws int
}

// PastSeason returns the top 10 of a finished season.
func PastSeason(number int) []SeasonStanding {
	v := pastSeasons.Get(key(number))
	if v == nil {
		return nil
	}
	var out []SeasonStanding
	for _, e := range strings.Split(v.(string), ",") {
		f := strings.Split(e, ":")
		if len(f) != 3 {
			continue
		}
		r, _ := strconv.Atoi(f[1])
		wld := strings.Split(f[2], "-")
		if len(wld) != 3 {
			continue
		}
		w, _ := strconv.Atoi(wld[0])
		l, _ := strconv.Atoi(wld[1])
		d, _ := strconv.Atoi(wld[2])
		out = append(out, SeasonStanding{f[0], r, w, l, d})
	}
	return out
}
