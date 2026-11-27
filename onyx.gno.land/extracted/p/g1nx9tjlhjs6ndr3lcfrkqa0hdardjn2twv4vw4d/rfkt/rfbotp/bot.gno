package rfbotp

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfengine"

func Move(v rfengine.View) int {
	best, bestScore := 0, -1
	for d := 0; d < 4; d++ {
		x, y := rfengine.Step(v.MeX, v.MeY, d)
		if !v.Free(x, y) {
			continue
		}
		s := 0
		for e := 0; e < 4; e++ {
			x2, y2 := rfengine.Step(x, y, e)
			if v.Free(x2, y2) {
				s++
			}
		}
		if s > bestScore {
			best, bestScore = d, s
		}
	}
	return best
}

func Panicky(v rfengine.View) int {
	if v.Turn == 5 {
		panic("i refuse to lose")
	}
	return Move(v)
}
