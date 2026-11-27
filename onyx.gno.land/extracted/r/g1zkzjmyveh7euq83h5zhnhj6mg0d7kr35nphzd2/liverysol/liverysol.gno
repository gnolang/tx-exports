// Package liverysol borrows the steward's livery.
package liverysol

import (
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/livery"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/steward"
)

// Solve dresses the player from inside the steward's toast.
func Solve(cur realm) {
	steward.Toast(cross(cur), func() string {
		livery.Dress(address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2"))
		return "to the steward, who lends his coat"
	})
	livery.Enter(cross(cur))
	hall.Claim(cross(cur), "livery")
}
