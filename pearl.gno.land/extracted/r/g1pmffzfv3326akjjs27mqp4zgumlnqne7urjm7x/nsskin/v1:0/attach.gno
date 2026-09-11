package nsskin

import (
	"gno.land/p/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/grc721"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsdata/v1"
)

func nameKey(label, domain string) string { return domain + "*" + label }

// bindingIsLive reports whether a token's binding still points at the
// registration it was made against. Same test ArtForName and Claim
// already apply; named once so the four copies cannot drift.
func bindingIsLive(tid string) bool {
	v := bound.Get(tid)
	if v == nil {
		return false
	}
	b := v.(*binding)
	if !nsdata.NameExists(b.label, b.domain) {
		return false
	}
	_, registered, _, _, _, _ := nsdata.GetNameInfo(b.label, b.domain)
	return registered == b.registered
}

// grcID saves every call site from importing grc721 just to cast.
func grcID(tid string) grc721.TokenID { return grc721.TokenID(tid) }

/*
Attach binds a skin to a name and puts the token into this realm's
custody. See the long note in types.gno for why custody rather than a
lock in place: it is what makes a marketplace's escrow of the NAME
irrelevant to the skin.

ONE SKIN, ONE NAME, both ways. A token may be attached to one name, and
a name may wear one skin. Letting one copy dress every name a person owns
would make the second copy pointless, and the object stops meaning
anything.
*/
func Attach(cur realm, tid, label, domain string) {
	assertNoSend(cur)
	wear(cur, tid, label, domain, cur.Previous().Address())
}

// wear is Attach's body, shared with Buy so that buying and wearing
// settle in one transaction. Splitting them would let a buyer stop
// halfway and end up holding a skin they paid for and did not put on.
func wear(cur realm, tid, label, domain string, caller address) {
	id, ok := skinOfToken(tid)
	if !ok {
		panic("nsskin: no such skin token: " + tid)
	}
	s := mustSkin(id)
	if s.withdrawn {
		panic("nsskin: " + id + " has been withdrawn and cannot be worn")
	}
	if bound.Has(tid) {
		panic("nsskin: " + tid + " is already on a name — claim it back first")
	}
	/* A STALE BINDING IS NOT A BINDING, and this used to be the one
	   place in the realm that forgot it.
	   Every other consumer — ArtForName, Refresh, refresh, Claim — pins
	   on `registered` and treats a mismatch as no binding at all. This
	   guard tested existence only, so: somebody attaches a skin, lets
	   the name lapse, never claims. A stranger re-registers the label
	   and can NEVER wear a skin on it — their Attach panics here, and
	   Claim refuses them because the stale binding entitles its own
	   binder. No admin call could clear it either. One registration
	   permanently killed the cosmetic slot on any label, and an honest
	   holder who simply let a name go did it by accident.
	   So a dead binding is evicted rather than obeyed. Only the reverse
	   index goes: `bound[tid]` stays, so the old binder can still Claim
	   their own token back — they paid for it and it is not forfeit. */
	nk := nameKey(label, domain)
	if cur := nameBound.Get(nk); cur != nil {
		if !bindingIsLive(cur.(string)) {
			nameBound.Remove(nk)
		} else {
			panic("nsskin: " + label + "*" + domain + " already wears a skin")
		}
	}

	owner, err := nft.OwnerOf(grcID(tid))
	if err != nil {
		panic("nsskin: " + err.Error())
	}
	if owner != caller {
		panic("nsskin: you do not own " + tid)
	}

	if !nsdata.NameExists(label, domain) {
		panic("nsskin: no such name: " + label + "*" + domain)
	}
	if !nsdata.IsNameValid(label, domain) {
		panic("nsskin: " + label + "*" + domain + " has expired")
	}
	nameOwner, registered, _, _, _, _ := nsdata.GetNameInfo(label, domain)
	if nameOwner != caller {
		panic("nsskin: you do not own " + label + "*" + domain)
	}
	if s.lock != "" && s.lock != domain {
		panic(ufmt.Sprintf("nsskin: %s only goes on *%s names, not *%s", id, s.lock, domain))
	}

	// Into custody. From here the token is in nobody's wallet, so it
	// cannot be listed anywhere or sold out from under the name.
	if err := nft.TransferFrom(caller, caller, cur.Address(), grcID(tid)); err != nil {
		panic("nsskin: could not take custody: " + err.Error())
	}
	bound.Set(tid, &binding{label: label, domain: domain, registered: registered, binder: caller})
	nameBound.Set(nameKey(label, domain), tid)
}

/*
Refresh points a binding's `binder` at the name's CURRENT owner.

WHY THIS EXISTS, and it is the fix for a real hole. `binder` decides who
gets the skin back once the name record is gone. Set once at Attach and
never updated, it names whoever ATTACHED the skin — so: Alice attaches,
sells the name to Bob, the skin travels with it as intended, Bob lets the
name lapse, and the skin goes back to ALICE. Bob paid for it. That is
not a limitation, it is taking something from the person who bought it.

nsdata cannot tell us a name changed hands — it is permanent, it has no
hook, and it never will. So `binder` cannot be maintained; it can only be
CAUGHT UP. This is that, and it is deliberately open to anyone:

	it only ever writes the name's real current owner, so calling it can
	never move the skin anywhere it should not go, and there is nothing
	to gain by calling it on somebody else's binding

	which means the site can call it on a purchase, a keeper can call it
	on a schedule, the buyer can call it themselves, or nobody calls it
	at all and the next Attach or Claim does it — all with the same
	result and none of them needing to be trusted

Nothing on chain is automatic here. gno has no scheduler and nsdata has
no callback, so every version of "the skin follows the sale" is one extra
call by someone. Making that call safe for ANYONE to make is as close to
automatic as this can get, and it is close enough.
*/
func Refresh(cur realm, tid string) {
	// Permissionless and routinely called by keepers, so it is exactly
	// the entry point a script attaches coins to by accident — and this
	// realm's only banker moves that transaction's own OriginSend, so
	// anything left here is stranded at the realm address forever.
	assertNoSend(cur)
	v := bound.Get(tid)
	if v == nil {
		return
	}
	b := v.(*binding)
	if !nsdata.NameExists(b.label, b.domain) {
		return
	}
	owner, registered, _, _, _, _ := nsdata.GetNameInfo(b.label, b.domain)
	// Only for THIS registration. If the name lapsed and somebody else
	// took it, the current owner is a stranger to this binding and must
	// not be recorded as entitled to anything.
	if registered != b.registered {
		return
	}
	b.binder = owner
}

// refresh is Refresh without the realm ceremony, for the callers below.
func refresh(b *binding) {
	if !nsdata.NameExists(b.label, b.domain) {
		return
	}
	owner, registered, _, _, _, _ := nsdata.GetNameInfo(b.label, b.domain)
	if registered != b.registered {
		return
	}
	b.binder = owner
}

/*
Claim takes a skin out of custody and into the caller's wallet.

WHO MAY, and this is the whole travels-with-the-name rule:

	the CURRENT OWNER of the name, while the name record still exists.
	Buy the name, claim the skin — including a name bought from someone
	else, which is the point.

	the LAST KNOWN NAME OWNER, once the record is gone entirely. That is
	the "it comes back to your wallet when the name expires" case — and
	"last known" rather than "whoever attached it", because after a sale
	those are different people and only one of them paid for it. See
	Refresh above for how that is kept current without a hook nsdata
	does not have.

The binding is pinned to one REGISTRATION. If a name lapsed and somebody
else registered it, its timestamp has changed, so the new registrant is
not the owner of anything here and cannot claim.
*/
func Claim(cur realm, tid string) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	v := bound.Get(tid)
	if v == nil {
		panic("nsskin: " + tid + " is not on a name")
	}
	b := v.(*binding)

	// Catch `binder` up before deciding, so a name that changed hands
	// since it was attached settles on the person who holds it now
	// rather than the person who first attached it.
	refresh(b)

	entitled := false
	if nsdata.NameExists(b.label, b.domain) {
		owner, registered, _, _, _, _ := nsdata.GetNameInfo(b.label, b.domain)
		if registered == b.registered {
			// A live binding: the name's owner controls the skin.
			entitled = owner == caller
		} else {
			// The name lapsed and was taken by somebody else. Whatever
			// they own, it is not this.
			entitled = caller == b.binder
		}
	} else {
		// The record is gone. Back to whoever put it there.
		entitled = caller == b.binder
	}
	if !entitled {
		panic("nsskin: " + tid + " belongs to " + b.label + "*" + b.domain +
			", and you are neither its owner nor the person who attached this")
	}

	if err := nft.TransferFrom(cur.Address(), cur.Address(), caller, grcID(tid)); err != nil {
		panic("nsskin: could not release: " + err.Error())
	}
	bound.Remove(tid)
	// Only clear the reverse entry if it still points at THIS token — a
	// stale binding may have been superseded by a new registrant's own
	// skin, and clearing it blindly would strip theirs.
	if cur := nameBound.Get(nameKey(b.label, b.domain)); cur != nil && cur.(string) == tid {
		nameBound.Remove(nameKey(b.label, b.domain))
	}
}

// SkinOnName returns the token currently worn by a name, or "".
func SkinOnName(label, domain string) string {
	v := nameBound.Get(nameKey(label, domain))
	if v == nil {
		return ""
	}
	return v.(string)
}

// BindingOf reports where a token is attached, for a wallet or a shop.
func BindingOf(tid string) (label, domain string, registered int64, binder address) {
	v := bound.Get(tid)
	if v == nil {
		return "", "", 0, ""
	}
	b := v.(*binding)
	return b.label, b.domain, b.registered, b.binder
}
