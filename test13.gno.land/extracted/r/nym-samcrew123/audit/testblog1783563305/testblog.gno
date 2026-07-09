package testblog1783563305

import "gno.land/p/nt/bptree/v0"

var moderatorList = bptree.NewBPTree32()

// AddModerator marque addr comme modérateur.
func AddModerator(_ realm, addr string) {
	moderatorList.Set(addr, true)
}

// RemoveModerator reproduit le bug du blog : Set(false) au lieu de Remove.
func RemoveModerator(_ realm, addr string) {
	moderatorList.Set(addr, false)
}

// isModerator reproduit le bug : teste only 'found', pas la valeur.
func isModerator(addr string) bool {
	_, found := moderatorList.Get(addr)
	return found
}

// ModOnlyAction panique si l'appelant n'est pas modérateur.
func ModOnlyAction(cur realm) string {
	caller := cur.Previous().Address()
	if !isModerator(caller.String()) {
		panic("not moderator")
	}
	return "executed"
}

func Render(_ string) string { return "testblog" }
