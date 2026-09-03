package crazy_wall

import "strconv"

type Graffiti struct {
	Artist string
	Text   string
}

var wall []Graffiti

func Spray(_ realm, artist, text string) int {
	idx := len(wall)
	wall = append(wall, Graffiti{Artist: artist, Text: text})
	return idx
}

func Render(_ string) string {
	out := "CRAZY GRAFFITI WALL - " + strconv.Itoa(len(wall)) + " tags\n"
	for i, g := range wall {
		out += "  #" + strconv.Itoa(i+1) + " " + g.Artist + ": " + g.Text + "\n"
	}
	return out
}
