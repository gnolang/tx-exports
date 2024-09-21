package minesweeper

import (
	"math/rand"
	"std"
	"strconv"
	"strings"

	"gno.land/p/demo/ufmt"
	"gno.land/p/grepsuzette/pr2554/v1/ternary"
)

const (
	urlImage              = "https://upload.wikimedia.org/wikipedia/commons/b/b1/497-octopus.svg"
	attributionAboveImage = "Vincent Le Moign, CC BY 4.0 <https://creativecommons.org/licenses/by/4.0>, via Wikimedia Commons"
	rRoot                 = "/r/grepsuzette/pr2554/v4"
)

var prng *rand.Rand

func Intn(n int) int {
	if prng == nil {
		// Note: our PRNG is not stateful as calling Render is not going
		// to modify this stateless realm. We initialize it here when still nil
		// this creates the randomness we need (seeded from blockchain's height)
		prng = rand.New(rand.NewPCG(uint64(std.GetHeight()), uint64(9)))
	}
	return prng.IntN(n)
}

func Render(path string) string {
	// out := "**Underwater Minesweeper**\n\n"
	out := "&nbsp;"
	out += css()
	board, x, y, _ := parsePath(path)
	lost := false
	if x != -1 && y != -1 {
		lost = !board.Reveal(x, y)
	}
	won := !lost && didWin(board)

	// if won {
	// 	out += `<center><b>You are a true underwater hero!</b><br><br>

	// <img src="` + urlImage + `" width=256 />

	// [ [New game](/r/demo/games/minesweeper) | [Back to demo/games](/r/demo/games) ]</center>
	// `
	// } else {
	// display the minefield as a matrix of buttons
	out += header(won, lost)
	repr := board.ToHexRepr()
	for j := range board.cells {
		for i := range board.cells[j] {
			out += button(i, j, board.cells[j][i], won, lost, repr, x, y)
		}
		out += "<br />"
	}
	out += footer(won, lost)
	// }

	// if debug {
	// 	out += ufmt.Sprintf(
	// 		"--- played x=%d y=%d height=%d path=%s error:%s",
	// 		x, y, std.GetHeight(), path, "",
	// 	)
	// }
	return out
}

func didWin(board *Board) bool {
	missing := 0
	for j := range board.cells {
		for i := range board.cells[j] {
			cell := &board.cells[j][i]
			if !cell.IsMine && !cell.IsRevealed {
				missing++
			}
		}
	}
	return missing == 0
}

func button(x, y int, cell Cell, won, lost bool, repr string, playedX, playedY int) string {
	var char string
	revealed := cell.IsRevealed || lost || won
	classes := []string{"btn"}
	if revealed {
		classes = append(classes, "d")
	}
	if playedX == x && playedY == y && cell.IsMine && (lost || won) {
		classes = append(classes, "exploded")
	}
	switch {
	case !revealed:
		char = "&nbsp;"
	case cell.IsMine:
		char = ternary.String(lost, "💣", "🌈")
	case cell.AdjacentMines <= 0:
		char = "&nbsp;"
	case cell.AdjacentMines > 8:
		panic("should not happen")
	default:
		classes = append(classes, "m"+strconv.Itoa(cell.AdjacentMines))
		char = strconv.Itoa(cell.AdjacentMines)
	}
	// if ?querystring were allowed, we could then use <button> for this.
	// return "<button class='...'>" + char + "</button>"
	// instead <a> will be used for now
	link := ternary.String(lost || won, "#", ufmt.Sprintf(
		"/r/demo/games/minesweeper:state=%s&x=%d&y=%d",
		repr, x, y,
	))
	return ufmt.Sprintf(
		`<a href="%s" draggable="false" class="%s">%s</a>`,
		link, strings.Join(classes, " "), char,
	)
}

func css() string {
	return `<style type="text/css">
    form button, form a.btn {
	    appearance: button;
	    box-sizing: border-box;
		display: inline-block;
        margin: 0; 
		padding: 0;
        background-color: #ccc;
        border: 2px outset #eee;
        height: 32px;
        width: 32px;
		line-height: 32px;
		text-align: center;
        cursor: pointer;
        font-weight: 800;
		text-decoration: none;
		draggable: none;
		user-select: none;
    }
    form button.d, form a.btn.d {
        cursor: default;
        border-bottom: 1px solid #888;
        border-left: 1px solid #888;
        border-right: none;
        border-top: 2px solid transparent;
		height: 32px;
    }
	form button:hover, form a.btn:hover {
        background-color: #ddd;
    }
	form button.d:hover, form a.btn.d:hover {
        background-color: #ccc;
    }
    form button.m1, form a.btn.m1 { color: blue; }
    form button.m2, form a.btn.m2 { color: green; }
    form button.m3, form a.btn.m3 { color: red; }
    form button.m4, form a.btn.m4 { color: navy; }
    form button.m5, form a.btn.m5 { color: brown; }
    form button.m6, form a.btn.m6 { color: purple; }
    form button.m7, form a.btn.m7 { color: cyan; }
    form button.m8, form a.btn.m8 { color: orange; }
    form button.exploded, form a.btn.exploded { 
        background-color: #ccc;
        opacity: 1;
        animation: 
            0.5s 0.1s backwards ease-in explode,
            1s 0.6s alternate infinite ease glowing;
	}
    @keyframes explodedisable {
        from {
            transform: scale(150);
            opacity: 0.1;
        }
        to {
        background-color: #ccc;
            transform: scale(1);
        }
    }
    @keyframes glowing {
        from {
        text-shadow:
            -1px -1px 40px rgba(255,0,0,.1),
            1px 1px 40px rgba(255,0,0,.1);
        }
        to {
            text-shadow:
               -1px -1px 8px rgba(255,0,0,.54),
               1px 1px 8px rgba(255,0,0,.54);
        }
    }
    div#board { 
		display: flex; 
		flex-direction: row;
	}
	#left {
		flex-shrink: 1;
        padding-right: 5px;
	}
	#right {
		flex-shrink: 0;
		flex-basis: auto;
		border: 3px double #ccc;
	}
	div#board.lost {
		animation: 1s ease-in-out booom;
	}
    @keyframes booom {
		0% {
			transform: scale(8) rotateZ(7720deg) translateX(200px);
			filter: brightness(2.9);
		}
		20% { filter: translateX(0); }
		90% { filter: brightness(1.0); }
		100% {
			transform: scale(1) rotate(0deg);
		}
	}
    .rotated {
        width: 200px;
        height: 200px;
        background-color: lightblue;
        transform: rotateZ(45deg) rotateX(45deg) rotateY(45deg);
        perspective: 1000px;
    }
</style>
`
}

func header(won, lost bool) string {
	var title, legend string
	if won {
		title = "You saved my underwater realm!"
		// unlock nft/badge?
		legend = `
		🐠 = hooray!<br>
		🦐 = so brave<br>
		🦈 = thank you<br>
		🐳 = well done<br>`
	} else if !lost {
		title = "Save me, my underwater realm is threatened by water mines."
		legend = `
🐠 = yes<br>
🦐 = it's true<br>
🦈 = yep<br>
🐳 = true that<br>

[< quit to games](/r/demo/games)`
	} else {
		// Nice try, boomer 🤷
		// title = "<b>Ayaa!!</b> 🤯🤯🤯🤯🤯\n\n"
		// title += "Alas you hit a mine."
		title = "Alas you hit a mine!"
		// legend = `
		// 🐠 = yes<br>
		// 🦐 = it's true<br>
		// 🦑 = please<br>
		// 🐙 = help<br>
		// 🦈 = yep<br>
		// 🐳 = true that<br>`
	}

	return `<form><strong>` + title + `<br /> &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;/</strong>
<div id="board" ` + ternary.String(lost, "class='lost'", "") + `>
<div id="left">
<img src="` + urlImage + `" width=128 title="I was drawn by Vincent Le Moign, CC BY 4.0 via Wikimedia Commons" /><br>` + legend + `</div>
<div id="right">
`
}

func footer(won, lost bool) string {
	out := ``

	if lost || won {
		out += "</div>\n</div>\n\n[ [New game](/r/demo/games/minesweeper) | " +
			"[Back to demo/games](/r/demo/games) ]\n\n"
	}
	out += `
</div>
</div>
</form>
`
	return out
	// [Sorry, I need to go](/r/demo/games)
}

// Decompose path, into valid game and played coordinates (or -1,-1)
// The path is like "state=<hexadecimalBytes>&move=c3"
//
//   - state is empty or 9 characters,
//     imagine the following but without the \n: "-OX\nO--\n---".
//     O always plays first.
//
//   - move coordinate ranges from "a1" to "c3" but can be empty.
//
//   - debug &debug enables printing of a debug line.
func parsePath(path string) (game *Board, x, y int, debug bool) {
	h, e := BreakToMap(path)
	if e != nil {
		panic(e)
	}
	game = BoardFromRepr(h["state"])
	_, debug = h["debug"]
	x, y = -1, -1
	if sx, hasX := h["x"]; hasX {
		if n, e := strconv.Atoi(sx); e == nil {
			x = n
		}
	}
	if sy, hasY := h["y"]; hasY {
		if n, e := strconv.Atoi(sy); e == nil {
			y = n
		}
	}
	return game, x, y, debug
}

// Break down a string of url parameters to map[string]string.
// E.g. "foo=a&bar=b" -> (map[string]string{foo:"a", bar:"b"}, nil)
func BreakToMap(querystring string) (map[string]string, error) {
	m := make(map[string]string)
	for _, s := range strings.Split(querystring, "&") {
		if len(strings.TrimSpace(s)) == 0 {
			continue
		}
		idx := strings.Index(s, "=")
		if idx > -1 {
			m[s[:idx]] = s[idx+1:]
		} else {
			m[s] = ""
		}
	}
	return m, nil
}
