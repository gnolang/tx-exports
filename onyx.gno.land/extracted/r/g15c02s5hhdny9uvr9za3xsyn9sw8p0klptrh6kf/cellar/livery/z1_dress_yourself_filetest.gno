// Calling the wardrobe from your own realm: you are the realm acting, not
// the steward.

// PKGPATH: gno.land/r/g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2/tailor

package tailor

import "gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/livery"

func main(cur realm) {
	livery.Dress(address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2"))
}

// Error:
// livery: only the steward hands out the livery
