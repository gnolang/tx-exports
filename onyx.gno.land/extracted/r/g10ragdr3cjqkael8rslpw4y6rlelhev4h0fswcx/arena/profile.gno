package arena

import (
	"chain"
	"chain/runtime"
	"strings"
)

// Register opens a profile for the calling account.
// handle is 3–16 chars of a-z, 0-9 and underscore. referrer may be empty
// or the bech32 address of an existing member. A member can register once.
func Register(cur realm, handle, name, bio, referrer string) {
	who := caller(cur)
	mustNoPay()
	if profileByAddr(who) != nil {
		panic("already registered")
	}
	handle = strings.ToLower(strings.TrimSpace(handle))
	if !validHandle(handle) {
		panic("bad handle")
	}
	if state.byHandle.Has(handle) {
		panic("handle taken")
	}
	if name == "" {
		name = handle
	}
	name = cleanLine(name, maxNameRunes, maxNameBytes, "name", false)
	bio = cleanLine(bio, maxBioRunes, maxBioBytes, "bio", true)

	var ref address
	referrer = strings.TrimSpace(referrer)
	if referrer != "" {
		if len(referrer) > 60 {
			panic("bad referrer")
		}
		ref = address(referrer)
		if !ref.IsValid() {
			panic("bad referrer")
		}
		if ref == who {
			panic("self referral")
		}
		if profileByAddr(ref) == nil {
			panic("referrer not registered")
		}
	}

	p := &Profile{
		Addr:     who,
		Handle:   handle,
		Name:     name,
		Bio:      bio,
		Referrer: ref,
		Joined:   runtime.ChainHeight(),
	}
	state.byAddr.Set(who.String(), p)
	state.byHandle.Set(handle, p)
	state.books.Set(who.String(), &book{})
	chain.Emit(
		"ArenaRegister",
		"addr", who.String(),
		"handle", handle,
		"referrer", ref.String(),
	)
}

// UpdateProfile replaces the display name and bio. The handle stays.
func UpdateProfile(cur realm, name, bio string) {
	who := caller(cur)
	mustNoPay()
	p := mustMember(who)
	if strings.TrimSpace(name) == "" {
		name = p.Handle
	}
	p.Name = cleanLine(name, maxNameRunes, maxNameBytes, "name", false)
	p.Bio = cleanLine(bio, maxBioRunes, maxBioBytes, "bio", true)
	chain.Emit("ArenaProfile", "addr", who.String(), "handle", p.Handle)
}

// Follow records that the caller follows handle.
func Follow(cur realm, handle string) {
	who := caller(cur)
	mustNoPay()
	self := mustMember(who)
	target := lookup(handle)
	if target == nil {
		panic("unknown handle")
	}
	if target.Addr == who {
		panic("cannot follow self")
	}
	k := followKey(who, target.Addr)
	if state.follows.Has(k) {
		panic("already following")
	}
	state.follows.Set(k, 1)
	state.fans.Set(fanKey(target.Addr, who), 1)
	self.Following++
	target.Followers++
	chain.Emit("ArenaFollow", "from", who.String(), "to", target.Addr.String(), "handle", target.Handle)
}

// Unfollow removes a follow.
func Unfollow(cur realm, handle string) {
	who := caller(cur)
	mustNoPay()
	self := mustMember(who)
	target := lookup(handle)
	if target == nil {
		panic("unknown handle")
	}
	k := followKey(who, target.Addr)
	if !state.follows.Has(k) {
		panic("not following")
	}
	state.follows.Remove(k)
	state.fans.Remove(fanKey(target.Addr, who))
	if self.Following > 0 {
		self.Following--
	}
	if target.Followers > 0 {
		target.Followers--
	}
	chain.Emit("ArenaUnfollow", "from", who.String(), "to", target.Addr.String(), "handle", target.Handle)
}

// Following reports whether from follows the handle.
func Following(from address, handle string) bool {
	target := lookup(handle)
	if target == nil {
		return false
	}
	return state.follows.Has(followKey(from, target.Addr))
}
