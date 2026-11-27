package rfengine

// Directions: 0 up, 1 right, 2 down, 3 left.
var dx = [4]int{0, 1, 0, -1}
var dy = [4]int{-1, 0, 1, 0}

type View struct {
	W, H   int
	Cells  []byte // 0 empty, 1 wall/trail
	MeX    int
	MeY    int
	OppX   int
	OppY   int
	Turn   int
}

func (v View) Free(x, y int) bool {
	if x < 0 || y < 0 || x >= v.W || y >= v.H {
		return false
	}
	return v.Cells[y*v.W+x] == 0
}

func Step(x, y, d int) (int, int) { return x + dx[d&3], y + dy[d&3] }

type Bot func(v View) int

// Result: 0 draw, 1 A wins, 2 B wins. Moves is the canonical string.
func Play(a, b Bot, w, h, maxTurns int) (int, int, string) {
	cells := make([]byte, w*h)
	ax, ay, bx, by := 1, h/2, w-2, h/2
	cells[ay*w+ax], cells[by*w+bx] = 1, 1
	moves := make([]byte, 0, 2*maxTurns)
	for t := 0; t < maxTurns; t++ {
		va := View{W: w, H: h, Cells: cells, MeX: ax, MeY: ay, OppX: bx, OppY: by, Turn: t}
		vb := View{W: w, H: h, Cells: cells, MeX: bx, MeY: by, OppX: ax, OppY: ay, Turn: t}
		da := a(va) & 3
		db := b(vb) & 3
		moves = append(moves, byte('0'+da), byte('0'+db))
		nax, nay := Step(ax, ay, da)
		nbx, nby := Step(bx, by, db)
		aDead := !va.Free(nax, nay)
		bDead := !vb.Free(nbx, nby)
		if nax == nbx && nay == nby {
			aDead, bDead = true, true
		}
		if aDead || bDead {
			switch {
			case aDead && bDead:
				return 0, t + 1, string(moves)
			case aDead:
				return 2, t + 1, string(moves)
			default:
				return 1, t + 1, string(moves)
			}
		}
		ax, ay, bx, by = nax, nay, nbx, nby
		cells[ay*w+ax], cells[by*w+bx] = 1, 1
	}
	return 0, maxTurns, string(moves)
}
