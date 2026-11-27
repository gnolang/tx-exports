// Writing a field of another realm's object is refused: the keeper cannot
// be replaced from outside.

// PKGPATH: gno.land/r/g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2/seize

package seize

import "gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/rack"

func main(cur realm) {
	rack.Ledger.Keeper = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")
}

// Error:
// cannot directly modify readonly tainted object (use a method or crossing function): (const (ref(gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/rack) package{})).Ledger.Keeper
