// Package admins lets a fixed set of addresses change a realm's gnotif
// triggers. The realm passes the handle gnotif.Open returned straight to New,
// keeps the *Admins unexported, and on each call gives its gnotif identity,
// minted in the crossing function the admin called.
package admins

import (
	"chain/runtime"

	"gno.land/p/g13rqvks880v0hmlfepcj0kkudq0js38d3pc5k6a/gnotif/trigger/v0"
)

// Handle is the method set of the registry's *Handle.
type Handle interface {
	Set(cur realm, name string, t trigger.Trigger) string
	Remove(cur realm, name string)
}

// Admins holds a realm's handle and the addresses allowed to use it.
type Admins struct {
	h      Handle
	admins map[address]bool
}

// New returns an Admins over the handle h. It panics with no admin.
func New(h Handle, addrs ...address) *Admins {
	if len(addrs) == 0 {
		panic("at least one admin")
	}
	a := &Admins{h: h, admins: make(map[address]bool, len(addrs))}
	for _, addr := range addrs {
		if !addr.IsValid() {
			panic("invalid admin address " + addr.String())
		}
		a.admins[addr] = true
	}
	return a
}

// Set stores t under name and returns its id, when the realm's caller is an
// admin. me is the realm's gnotif identity, cur.Sub(gnotif.Subpath), and its
// Previous is the caller.
func (a *Admins) Set(_ int, me realm, name string, t trigger.Trigger) string {
	a.mustAdmin(0, me)
	return a.h.Set(cross(me), name, t)
}

// Remove removes the trigger under name, when the realm's caller is an admin.
func (a *Admins) Remove(_ int, me realm, name string) {
	a.mustAdmin(0, me)
	a.h.Remove(cross(me), name)
}

func (a *Admins) mustAdmin(_ int, me realm) {
	if !me.IsCurrent() {
		panic("me is not current: mint it in the crossing function the admin called")
	}
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("sign with your own key, not a session key")
	}
	if caller := me.Previous().Address(); !a.admins[caller] {
		panic(caller.String() + " is not an admin")
	}
}
