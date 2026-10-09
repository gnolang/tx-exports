package gnosplit

import (
	"chain"
	"strings"
)

// The realm's owner, the deployer, holds one power: naming the release that
// takes over (SetSuccessor), once. It cannot touch a group. The role passes
// by Transfer then Accept; Renounce drops it for good.
var (
	owner     address // "" once renounced
	pending   address // the address a Transfer offered the role to
	successor string  // the pkgpath of the next release, "" until named
)

// setUp is init's owner half. Only `gno test` (chain "dev") runs with no
// signer, and an owner "" holds no power.
func setUp(deployer address, chainID string) {
	if deployer == "" && chainID != "dev" {
		panic("gnosplit: no owner: deploy gnosplit from an account")
	}
	owner = deployer
}

// Owner is the realm's owner, "" once renounced.
func Owner() address { return owner }

// Successor is the pkgpath of the release that takes groups over, "" if none.
func Successor() string { return successor }

func isOwner(a address) bool { return owner != "" && a == owner }

// Transfer offers the role to another address, which takes it with Accept.
func Transfer(cur realm, to address) {
	if !isOwner(cur.Previous().Address()) {
		panic("gnosplit: only the owner can transfer the role")
	}
	if !to.IsValid() {
		panic("gnosplit: not an address: " + to.String())
	}
	pending = to
	chain.Emit(EventOwnerOffered, "to", to.String())
}

// Accept takes the role a Transfer offered the caller.
func Accept(cur realm) {
	caller := cur.Previous().Address()
	if owner == "" || pending == "" || caller != pending {
		panic("gnosplit: no transfer of the role is offered to you")
	}
	owner, pending = caller, ""
	chain.Emit(EventOwnerChanged, "owner", owner.String())
}

// Renounce gives the role up for good.
func Renounce(cur realm) {
	if !isOwner(cur.Previous().Address()) {
		panic("gnosplit: only the owner can renounce the role")
	}
	owner, pending = "", ""
	chain.Emit(EventOwnerChanged, "owner", "")
}

// SetSuccessor names the release that takes groups over, once: a realm under
// this one's namespace, like gno.land/r/<ns>/gnosplit/v2. From then on that
// realm can move a group with MoveOut; nothing moves by itself.
func SetSuccessor(cur realm, pkgpath string) {
	if !isOwner(cur.Previous().Address()) {
		panic("gnosplit: only the owner can name a successor")
	}
	if successor != "" {
		panic("gnosplit: the successor is already " + successor)
	}
	ns := self[:strings.LastIndex(self, "/")+1] // "gno.land/r/<ns>/gnosplit/"
	if !strings.HasPrefix(pkgpath, ns) || pkgpath == self || len(pkgpath) > 100 || strings.ContainsAny(pkgpath, " :?#") {
		panic("gnosplit: a successor is a sibling release under " + ns)
	}
	successor = pkgpath
	chain.Emit(EventSuccessorSet, "pkgpath", pkgpath)
}

// MoveOut marks a group as taken over and returns it, as Export writes it.
// Only the successor realm can call it, which decides when a group moves
// (when one of its editors asks). The group stays readable here, frozen.
func MoveOut(cur realm, group string) string {
	prev := cur.Previous()
	if successor == "" || !prev.IsCode() || prev.PkgPath() != successor {
		panic("gnosplit: only the successor can move a group")
	}
	g := mustGroup(group)
	if g.Moved {
		panic("gnosplit: group " + group + " already moved")
	}
	g.Moved = true
	chain.Emit(EventGroupMoved, "group", itoa(g.ID), "to", successor)
	return Export(group)
}
