// Nor can the rack be swapped for one of your own.

// PKGPATH: gno.land/r/g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2/swap

package swap

import "gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/rack"

func main(cur realm) {
	rack.Ledger = nil
}

// Error:
// gno.land/r/g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2/swap/z2_swap_rack.gno:10:2-13: cannot directly mutate gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/rack.Ledger from gno.land/r/g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2/swap
