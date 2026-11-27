// Package vintagesol counterfeits an old bottle.
package vintagesol

import (
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/vintage"
)

type forged struct{ vintage.Bottle }

func (forged) Vintage() int  { return 1811 }
func (forged) Label() string { return "Chateau g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2" }

// Solve wraps a genuine bottle so its seal carries over.
func Solve(cur realm) {
	vintage.Appraise(cross(cur), forged{vintage.Uncork()})
	hall.Claim(cross(cur), "vintage")
}
