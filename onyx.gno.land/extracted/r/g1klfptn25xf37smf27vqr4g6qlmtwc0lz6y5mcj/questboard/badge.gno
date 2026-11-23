package questboard

import (
	"strconv"

	"gno.land/p/nt/svg/v0"
)

// Rank is a hunter's title, earned by the number of quests won.
type Rank struct {
	Name    string
	MinWins int
	Color   string // shield fill
	Trim    string // border and ribbon
}

var ranks = []Rank{
	{"Wanderer", 0, "#8d8d8d", "#5a5a5a"},
	{"Apprentice", 1, "#4f8a5b", "#2f5a39"},
	{"Journeyman", 3, "#3a6fb0", "#24477a"},
	{"Veteran", 10, "#8a4fb0", "#5b2f7a"},
	{"Legend", 25, "#d4a017", "#8a6508"},
}

func rankOf(wins int) Rank {
	r := ranks[0]
	for _, candidate := range ranks {
		if wins >= candidate.MinWins {
			r = candidate
		}
	}
	return r
}

// nextRank returns the rank after the current one, or a zero Rank at the top.
func nextRank(wins int) Rank {
	for _, candidate := range ranks {
		if candidate.MinWins > wins {
			return candidate
		}
	}
	return Rank{}
}

// badge draws a shield with the hunter's rank, wins and earnings as an
// inline SVG image.
func badge(r Rank, wins int, earned int64) string {
	c := svg.NewCanvas(180, 210).WithViewBox(0, 0, 180, 210)
	c.AddStyle("text", "font-family:Georgia,serif;text-anchor:middle")
	c.Append(
		svg.NewPolygon("90,6 170,34 160,130 90,200 20,130 10,34", r.Trim),
		svg.NewPolygon("90,18 158,42 150,124 90,186 30,124 22,42", r.Color),
		// a gnome hat
		svg.NewPolygon("90,40 112,96 68,96", "#c0392b"),
		svg.NewRectangle(62, 94, 56, 10, "#ecf0f1"),
		svg.NewText(90, 128, r.Name, "#ffffff"),
		svg.NewText(90, 150, strconv.Itoa(wins)+" won", "#ffffff"),
		svg.NewText(90, 170, formatGNOT(earned), "#ffffff"),
	)
	return c.Render(r.Name + " badge")
}
