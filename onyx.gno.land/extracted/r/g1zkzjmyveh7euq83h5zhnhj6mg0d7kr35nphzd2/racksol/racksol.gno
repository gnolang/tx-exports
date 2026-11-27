// Package racksol reserves the prize through the posted ledger.
package racksol

import (
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/rack"
)

// Solve writes the reservation with a method call on the leaked tree.
func Solve(cur realm) {
	rack.Ledger.Reserved.Set("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2", rack.Prize)
	rack.Collect(cross(cur))
	hall.Claim(cross(cur), "rack")
}
