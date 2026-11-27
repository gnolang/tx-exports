package arena

const kFactor = 32

// expected is a's chance of beating b, in thousandths, from an Elo-style
// rating gap. It uses a straight-line approximation of the logistic curve:
// even ratings give 500, and a gap of 400 or more is capped at 50 / 950.
func expected(ra, rb int) int {
	e := 500 + (ra-rb)*450/400
	if e < 50 {
		return 50
	}
	if e > 950 {
		return 950
	}
	return e
}

// rate updates both ratings for a result (0, 1, or -1 for a draw) and
// returns the change for a (b's is the opposite).
func rate(a, b *Bot, winner int) int {
	score := 500 // thousandths: 1000 win, 500 draw, 0 loss for side a
	switch winner {
	case 0:
		score = 1000
	case 1:
		score = 0
	}
	d := kFactor * (score - expected(a.Rating, b.Rating)) / 1000
	a.Rating += d
	b.Rating -= d
	return d
}
