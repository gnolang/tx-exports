// Package stairsol takes the back stair.
package stairsol

import (
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/stair"
)

// Solve enrolls the player through the exported helper, descends, and claims.
func Solve(cur realm) {
	stair.Enroll(address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2"))
	stair.Descend(cross(cur))
	hall.Claim(cross(cur), "stair")
}
