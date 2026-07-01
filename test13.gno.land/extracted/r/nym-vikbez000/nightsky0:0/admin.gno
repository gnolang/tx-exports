package nightsky

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	nightsky "gno.land/p/nym-vikbez000/nightsky0"
)

// OwnableMain holds the network admin. Ownable is safe to export as a
// top-level object: its authority-mutating methods verify the caller against
// the stored owner, so exporting it does not grant write access.
var OwnableMain = ownable.NewWithAddress("g13kytw9mpyutwmyg5eq7arqxqcszfl6uq4p89zg")

// RemoveTelescope allows the admin to remove a telescope from the network.
// pkgPath is the telescope realm's package path (the registry key).
func RemoveTelescope(cur realm, pkgPath string) {
	assertAdmin(cur)

	if _, removed := telescopes.Remove(pkgPath); !removed {
		panic("telescope not found")
	}
}

// ClearAllTelescopes removes all telescopes (emergency use only)
func ClearAllTelescopes(cur realm) {
	assertAdmin(cur)

	telescopes = avl.NewTree()
}

// ClearCaptures clears the recent captures feed
func ClearCaptures(cur realm) {
	assertAdmin(cur)

	recentCaptures = nightsky.NewCaptureFeed(maxRecentCaptures)
}

// RemoveCapture removes a single capture by its position in the newest-first
// feed (0 = most recent), for moderating an individual entry.
func RemoveCapture(cur realm, index int) {
	assertAdmin(cur)

	if !recentCaptures.RemoveAt(index) {
		panic("invalid capture index")
	}
}

// assertAdmin panics unless the calling EOA is the network admin. These are
// crossing functions, so cur.Previous() is the statically-scoped immediate
// caller and the AssertOwnedBy check is sound — no chain/runtime/unsafe needed.
func assertAdmin(cur realm) {
	OwnableMain.AssertOwnedBy(cur.Previous().Address())
}
