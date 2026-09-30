package golf

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

// The course's owner, the deployer, set at init: golf's only role. Every
// check is on the immediate caller (cur.Previous().Address()), never the
// signer, so a realm the owner calls cannot act in their name. The role
// passes by Transfer then Accept; Renounce freezes the course for good.
var (
	owner   address // "" once renounced
	pending address // the address a Transfer offered the role to, "" if none
)

// self is golf's own pkgpath, hub its gnoweb path: every link follows from
// them, so the same code serves under any namespace.
var (
	self           = unsafe.CurrentRealm().PkgPath()
	hub            = strings.TrimPrefix(self, "gno.land")
	officialPrefix = self[:strings.LastIndex(self, "/")+1] // the namespace's realms, as "…/"
)

// playURL is the 3D client every page links to (SetPlayURL moves it).
var playURL = "https://gnogolf.xyz/"

// successor is the realm that took this course over, "" until the owner
// names it, once (SetSuccessor).
var successor string

func init() { setUp(unsafe.OriginCaller(), runtime.ChainID()) }

// setUp is init: the deployer owns the course, and community publishing
// starts closed. Only `gno test` (chain "dev") runs it with no signer: the
// owner stays "", which holds no power, and publishing starts open, since
// nobody there could open it.
func setUp(deployer address, chainID string) {
	if deployer == "" && chainID != "dev" {
		panic("golf: no owner: golf must be deployed by an account")
	}
	owner, publishing = deployer, deployer == ""
}

// Owner is the course's owner, "" once renounced.
func Owner() address { return owner }

// Pending is the address a Transfer offered the role to, "" if none.
func Pending() address { return pending }

// Successor is the realm that took this course over, "" if none.
func Successor() string { return successor }

// isOwner is the one owner check: a live role, held by the caller.
func isOwner(caller address) bool { return owner != "" && caller == owner }

// Transfer offers the role to another address, which takes it with Accept.
// Offering it to the owner themselves cancels an offer.
func Transfer(cur realm, to address) {
	if !isOwner(cur.Previous().Address()) {
		panic("golf: only the owner can transfer the course")
	}
	if !to.IsValid() {
		panic("golf: not an address: " + to.String())
	}
	if to == owner {
		pending = ""
		chain.Emit(EventOwnershipOfferCancelled, "owner", owner.String())
		return
	}
	pending = to
	chain.Emit(EventOwnershipOffered, "owner", owner.String(), "to", to.String())
}

// Accept takes the role a Transfer offered the caller.
func Accept(cur realm) {
	caller := cur.Previous().Address()
	if owner == "" || pending == "" || caller != pending {
		panic("golf: no transfer of the course is offered to you")
	}
	from := owner
	owner, pending = caller, ""
	chain.Emit(EventOwnershipTransfer, "from", from.String(), "to", owner.String())
}

// Renounce gives the role up for good: no owner, no offer, and none possible.
func Renounce(cur realm) {
	if !isOwner(cur.Previous().Address()) {
		panic("golf: only the owner can renounce the course")
	}
	from := owner
	owner, pending = "", ""
	chain.Emit(EventOwnershipRenounced, "from", from.String())
}

// maxURL bounds the play link, maxPkgPath a successor's pkgpath.
const (
	maxURL     = 100
	maxPkgPath = 100
)

// SetPlayURL moves the link every page gives to the 3D client. Only the
// owner can. url is https://, at most 100 of letters, digits and "-._~/:%",
// with no query or fragment: a hole's link adds "?cup=…&hole=…" to it.
func SetPlayURL(cur realm, url string) {
	if !isOwner(cur.Previous().Address()) {
		panic("golf: only the owner can move the play link")
	}
	if !validURL(url) {
		panic("golf: a play link is https:// and up to 100 of a-z, A-Z, 0-9 and -._~/:%")
	}
	playURL = url
	chain.Emit(EventPlayURLSet, "url", url)
}

func validURL(u string) bool {
	if len(u) > maxURL || !strings.HasPrefix(u, "https://") || len(u) == len("https://") {
		return false
	}
	for i := 0; i < len(u); i++ {
		c := u[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte("-._~/:%", c) >= 0) {
			return false
		}
	}
	return true
}

// SetSuccessor names the realm that takes this course over, once and for
// good: a pkgpath under gno.land/r/, not golf itself, with no "", "." or ".."
// segment. Only the owner can. It moves and blocks nothing: the pages and
// Holes say where the course went, and play goes on here. golf does not check
// the realm exists: check the path before sending.
func SetSuccessor(cur realm, pkgpath string) {
	if !isOwner(cur.Previous().Address()) {
		panic("golf: only the owner can name a successor")
	}
	if successor != "" {
		panic("golf: the successor is already " + successor)
	}
	if !validPkgPath(pkgpath) || pkgpath == self {
		panic("golf: a successor is a realm's pkgpath, gno.land/r/ and up to 100 of a-z, 0-9 and _-/.")
	}
	successor = pkgpath
	chain.Emit(EventSuccessorSet, "successor", pkgpath)
}

// Hide takes a community hole ("<address>/<slug>", every version) off the
// lists (the hub, Holes, the 3D game), for a scam or abuse in its name or
// note; hide=false puts it back. Only the owner can. Its data, rounds and
// page stay, Community still has it, and a new version stays hidden. A hole
// already as asked is left alone, with no event.
func Hide(cur realm, slot string, hide bool) {
	if !isOwner(cur.Previous().Address()) {
		panic("golf: only the owner can hide a hole")
	}
	v := aliases.Get(slot)
	if v == nil {
		if e := find(slot); e != nil && !e.official {
			panic("golf: " + slot + " is a version: hide its hole, " + e.slot)
		}
		panic("golf: " + slot + " is not a community hole")
	}
	if hidden.Has(slot) == hide {
		return
	}
	// out of byAuthor, all the lists walk: they never read a hidden hole
	e := find(v.(string))
	a := e.by.String()
	row := a + " " + recentKey(e.height, slot[len(a)+1:])
	was := newestRow(a)
	if hide {
		hidden.Set(slot, true)
		byAuthor.Remove(row)
	} else {
		hidden.Remove(slot)
		byAuthor.Set(row, e.id)
	}
	moveAuthor(a, was, newestRow(a))
	chain.Emit(EventHoleHidden, "slot", slot, "hidden", strconv.FormatBool(hide))
}

// publishing is whether anyone can publish a community hole (PublishMine):
// closed at deploy (setUp), opened later without a redeploy.
var publishing bool

// Publishing is whether PublishMine is open.
func Publishing() bool { return publishing }

// SetPublishing opens community publishing (PublishMine) or closes it again.
// Only the owner can. Closing stops new holes and versions only: every hole
// published stays playable and listed. Setting it as it is does nothing.
func SetPublishing(cur realm, open bool) {
	if !isOwner(cur.Previous().Address()) {
		panic("golf: only the owner can open or close publishing")
	}
	if publishing == open {
		return
	}
	publishing = open
	chain.Emit(EventPublishingSet, "open", strconv.FormatBool(open))
}

func validPkgPath(p string) bool {
	if len(p) > maxPkgPath || !strings.HasPrefix(p, "gno.land/r/") {
		return false
	}
	for _, seg := range strings.Split(p[len("gno.land/r/"):], "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.IndexByte("_-/.", c) >= 0) {
			return false
		}
	}
	return true
}

// The events golf emits, and their attributes. A hole is always "hole", a
// player "player".
const (
	EventHolePublished           = "HolePublished"           // hole, slot, sha, by, official ("true"/"false")
	EventHoleRetired             = "HoleRetired"             // hole, next
	EventShot                    = "Shot"                    // hole, player, strokes, mode, shot ("angle,power,tick" as recorded)
	EventHoled                   = "Holed"                   // hole, player, strokes, mode, shots (the round's)
	EventRoundReset              = "RoundReset"              // hole, player
	EventOwnershipOffered        = "OwnershipOffered"        // owner, to
	EventOwnershipOfferCancelled = "OwnershipOfferCancelled" // owner
	EventOwnershipTransfer       = "OwnershipTransfer"       // from, to
	EventOwnershipRenounced      = "OwnershipRenounced"      // from
	EventPlayURLSet              = "PlayURLSet"              // url
	EventSuccessorSet            = "SuccessorSet"            // successor
	EventHoleHidden              = "HoleHidden"              // slot, hidden ("true"/"false")
	EventPublishingSet           = "PublishingSet"           // open ("true"/"false")
)
