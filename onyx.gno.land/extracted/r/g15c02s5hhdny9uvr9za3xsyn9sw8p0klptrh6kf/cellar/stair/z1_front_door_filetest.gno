// A realm knocking on the front door is turned away like anyone else.

// PKGPATH: gno.land/r/g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2/knock

package knock

import "gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/stair"

func main(cur realm) {
	stair.Appoint(cross(cur), address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2"))
}

// Error:
// stair: only the head steward appoints stewards
