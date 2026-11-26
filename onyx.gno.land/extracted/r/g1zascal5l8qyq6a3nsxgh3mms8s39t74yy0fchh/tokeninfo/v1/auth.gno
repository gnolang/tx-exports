package tokeninfo

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/r/nt/grc20reg/v0"
	"gno.land/r/sys/users"
)

const maxEditors = 10

// tokenExists and resolveName are variables only so tests can stand in for
// grc20reg and r/sys/users.
var (
	tokenExists = func(token string) bool { return grc20reg.Get(token) != nil }
	resolveName = func(name string) (address, bool) {
		data, isCurrent := users.ResolveName(name)
		if data == nil || !isCurrent {
			return "", false
		}
		return data.Addr(), true
	}
)

// authorize returns who is calling and with which role, or panics. A realm
// caller is trusted only as the token's own realm; a user caller (MsgCall or
// MsgRun) as the namespace owner or an editor.
func authorize(cur realm, token string) (address, string) {
	if !cur.IsCurrent() {
		panic("tokeninfo: invalid realm")
	}
	pkg, ns := mustToken(token)
	prev := cur.Previous()
	who := prev.Address()
	if !prev.IsUser() {
		if prev.PkgPath() == pkg {
			return who, RoleRealm
		}
		panic("tokeninfo: only " + pkg + " can write this profile from code")
	}
	if ownsNamespace(who, ns) {
		return who, RoleOwner
	}
	if IsEditor(token, who) {
		return who, RoleEditor
	}
	panic("tokeninfo: " + who.String() + " does not own " + pkg + " and is not an editor")
}

// mustToken checks that token is a valid token path listed in grc20reg, and
// returns its realm path and namespace.
func mustToken(token string) (pkg, ns string) {
	pkg, ns, ok := parseToken(token)
	if !ok {
		panic("tokeninfo: " + token + " is not a token path like gno.land/r/name/token.SYMBOL")
	}
	if !tokenExists(token) {
		panic("tokeninfo: " + token + " is not listed in grc20reg")
	}
	return pkg, ns
}

// ownsNamespace applies the same two rules the chain uses to let someone
// deploy under a namespace: it is their own address, or a name they hold now.
func ownsNamespace(who address, ns string) bool {
	if ns == "" || !who.IsValid() {
		return false
	}
	if who.String() == ns {
		return true
	}
	owner, ok := resolveName(ns)
	return ok && owner == who
}

// IsEditor reports whether addr was added as an editor of token.
func IsEditor(token string, addr address) bool {
	set := editors.Get(token)
	return set != nil && set.(*avl.Tree).Has(addr.String())
}

// CanEdit reports whether addr, signing a transaction itself, could write the
// profile of token right now. Apps use it to show or hide an edit button.
func CanEdit(token string, addr address) bool {
	_, ns, ok := parseToken(token)
	return ok && (ownsNamespace(addr, ns) || IsEditor(token, addr))
}
