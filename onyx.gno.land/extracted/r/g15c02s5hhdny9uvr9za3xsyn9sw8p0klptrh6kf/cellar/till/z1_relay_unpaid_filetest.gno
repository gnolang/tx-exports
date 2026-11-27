// Relaying through a realm without sending anything gets nothing.

// PKGPATH: gno.land/r/g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2/relay

package relay

import "gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/till"

func main(cur realm) {
	till.BuyRound(cross(cur))
}

// Error:
// till: a round is 100000ugnot; send it with the call
