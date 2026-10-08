// Package role is a role held by one address and passed in two steps
// (offer, accept), which its holder can cancel or renounce. A Role is pinned
// to the realm that made it (its home): every method that acts takes that
// realm's live cur and refuses any other value, so a *Role that leaked out of
// its realm can do nothing anywhere else.
package role

import (
	"chain"
	"chain/runtime/unsafe"
)

// Canonical reports whether a is a valid address in its one canonical
// spelling, lower case. The chain also takes the upper-case bech32 of an
// account, but realms compare and key addresses as strings, so every
// address argument that is stored, compared or paid to goes through this.
func Canonical(a address) bool {
	return !Upper(a) && a.IsValid()
}

// Upper reports whether a is spelled in upper case. Bech32 is all upper or
// all lower case (mixed case is not IsValid), and an address starts with its
// letter prefix "g", so the first byte tells: a scan of the 40 bytes costs
// far more gas, strings.ToLower more still.
func Upper(a address) bool {
	s := a.String()
	return len(s) > 0 && s[0] >= 'A' && s[0] <= 'Z'
}

// Role is kept by its home realm in an unexported variable.
type Role struct {
	home    string  // the realm that made it, the only one it answers
	name    string  // for events and messages ("owner", "guardian")
	holder  address // "" once renounced
	pending address // offered, "" if none
}

// New makes a role held by holder and pinned to the calling realm. Call it
// from the realm's init.
func New(name string, holder address) *Role {
	if !Canonical(holder) {
		panic("role: not an address")
	}
	return &Role{home: unsafe.CurrentRealm().PkgPath(), name: name, holder: holder}
}

// live checks that rlm is the home realm's runtime-current cur: a stale,
// stored, Previous() or foreign realm value is refused (Class 2). The _ int
// keeps the method non-crossing: v1.5.0 refuses crossing methods in /p/.
func (r *Role) live(_ int, rlm realm) {
	if !rlm.IsCurrent() || rlm.PkgPath() != r.home {
		panic("role: not the home realm's live cur")
	}
}

// Holder is who holds the role ("" once renounced).
func (r *Role) Holder() address { return r.holder }

// Pending is who was offered the role ("" if nobody).
func (r *Role) Pending() address {
	if r == nil { // no holder since a release renounced the role
		return ""
	}
	return r.pending
}

// Is reports whether the immediate caller of the home realm holds the role.
func (r *Role) Is(_ int, rlm realm) bool {
	r.live(0, rlm)
	return r.holder != "" && rlm.Previous().Address() == r.holder
}

// Must panics unless the immediate caller holds the role.
func (r *Role) Must(_ int, rlm realm) {
	if !r.Is(0, rlm) {
		panic("role: " + r.name + " only")
	}
}

// Offer offers the role to to. Offering it to the holder cancels an offer.
func (r *Role) Offer(_ int, rlm realm, to address) {
	r.Must(0, rlm)
	if !Canonical(to) {
		panic("role: not an address")
	}
	if to == r.holder {
		r.pending = ""
		chain.Emit("RoleOfferCancelled", "role", r.name)
		return
	}
	r.pending = to
	chain.Emit("RoleOffered", "role", r.name, "to", to.String())
}

// Accept takes the role offered to the caller.
func (r *Role) Accept(_ int, rlm realm) {
	r.live(0, rlm)
	c := rlm.Previous().Address()
	if r.holder == "" || r.pending == "" || c != r.pending {
		panic("role: nothing offered to you")
	}
	from := r.holder
	r.holder, r.pending = c, ""
	chain.Emit("RoleChanged", "role", r.name, "from", from.String(), "to", c.String())
}

// Renounce gives the role up for good.
func (r *Role) Renounce(_ int, rlm realm) {
	r.Must(0, rlm)
	r.holder, r.pending = "", ""
	chain.Emit("RoleRenounced", "role", r.name)
}

// ---- the release handover: a realm's role and its mirror in data ----

// Mirror is the holder: the mirror h when it exists (ok), as the previous
// release may have changed it after r was made, else r's ("" once renounced).
func Mirror(r *Role, h string, ok bool) address {
	if ok {
		return address(h)
	}
	if r == nil {
		return ""
	}
	return r.holder
}

// Adopt is r once it agrees with the mirror h: unchanged without a mirror
// (!ok) or when r already holds it, nil when the mirror says renounced,
// else a new role named name for h, pinned to the calling realm (New).
func Adopt(r *Role, name, h string, ok bool) *Role {
	if !ok || r != nil && h == r.holder.String() {
		return r
	}
	if h == "" {
		return nil
	}
	return New(name, address(h))
}
