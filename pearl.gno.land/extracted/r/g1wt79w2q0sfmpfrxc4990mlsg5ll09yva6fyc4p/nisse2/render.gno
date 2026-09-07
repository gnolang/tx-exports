package nisse2

import (
	"strconv"

	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/book"
)

func Render(path string) string {
	out := "# Nisse v2\n\n"
	out += "Frozen book: creatures + terrain live in `/p/.../nisse2/book`.\n"
	out += "Rules live in `/p/.../nisse2/rules`. This realm only stores players and applies outcomes.\n\n"
	out += "## Atlas " + strconv.Itoa(int(book.Width())) + "x" + strconv.Itoa(int(book.Height())) + "\n\n"
	out += "```\n"
	h := book.Height()
	w := book.Width()
	for y := uint64(0); y < h; y++ {
		line := ""
		for x := uint64(0); x < w; x++ {
			line += book.TerrainShort(book.Tile(x, y)) + " "
		}
		out += line + "\n"
	}
	out += "```\n\n"
	out += "## Players\n\n"
	if len(players) == 0 {
		out += "_None yet. Call MintPlayer._\n"
	} else {
		out += ListPlayerPositions() + "\n"
	}
	if path != "" {
		out += "\nPath: `" + path + "`\n"
	}
	return out
}
