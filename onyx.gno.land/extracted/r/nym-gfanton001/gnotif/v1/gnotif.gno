// Package gnotif is a registry of notification triggers. Each trigger names
// a realm and an event type to watch, and the text of the notification that
// gnotif servers send when a matching event lands on chain. A later registry
// version follows the rules in
// https://gnotif.xyz/docs/how-it-works/#rules-for-a-new-registry-version.
package gnotif

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/nym-gfanton001/gnotif/trigger/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/sys/names"
)

// Subpath is the subpath of a realm's gnotif identity: me := cur.Sub(gnotif.Subpath).
const Subpath = "gnotif"

// Trigger is an alias, so a dapp imports only the registry.
type Trigger = trigger.Trigger

// Handle changes the triggers of the realm that opened it. Each method also
// needs that realm's gnotif identity as its caller, so the pointer alone is
// useless to any other realm.
type Handle struct {
	target   string
	approver string // the namespace owner who signed the Open
}

var (
	triggers bptree.BPTree // id → record.encode()
	byTarget bptree.BPTree // target → []string of its active ids, oldest first
	handles  bptree.BPTree // target → its live *Handle
	lastID   seqid.ID
)

// idPrefix is the last element of the registry's path and a dash, such as
// "v1-": gnotifd takes an id only from the registry version it names.
var idPrefix = selfPath[strings.LastIndex(selfPath, "/")+1:] + "-"

// Open returns the handle that changes the triggers of the realm whose gnotif
// identity calls it. It panics while the realm holds a handle its namespace
// owner has not revoked. It also panics outside the owner's deploy of the
// realm and outside a call the owner signed and sent straight to the realm.
// r/sys/names says who the owner is.
func Open(cur realm) *Handle {
	me := cur.Previous()
	target := targetOf(0, me)
	if handles.Has(target) {
		panic(target + " already holds a handle: its namespace owner can Revoke it")
	}
	mustOwnerEntered(0, me, target)
	h := &Handle{target: target, approver: unsafe.OriginCaller().String()}
	handles.Set(target, h)
	return h
}

// Set stores t under name and returns its id. A new name gets a new id. On a
// name in use, t must watch the same event, filter and param: the id stays,
// so users who turned the trigger on keep it.
func (h *Handle) Set(cur realm, name string, t Trigger) string {
	h.mustHold(cur.Previous().PkgPath())
	if !validName(name, 1, maxName) {
		panic("invalid name")
	}
	validate(t)
	r := record{Target: h.target, Name: name, T: t}
	ids := activeOf(h.target)
	if id, old, ok := find(ids, name); ok {
		if old.T == t {
			return id
		}
		if old.T.Event != t.Event || old.T.Filter != t.Filter || old.T.Param != t.Param {
			panic(name + " watches a different event, filter or param: Remove it, then Set it again")
		}
		store(id, r, h.approver)
		return id
	}
	if len(ids) >= maxPerTarget {
		panic("too many triggers for target")
	}
	id := idPrefix + lastID.Next().String()
	store(id, r, h.approver)
	byTarget.Set(h.target, append(ids, id))
	return id
}

// Remove removes the trigger under name, and with it every user's choice to
// receive it.
func (h *Handle) Remove(cur realm, name string) {
	h.mustHold(cur.Previous().PkgPath())
	if !validName(name, 1, maxName) {
		panic("invalid name")
	}
	id, _, ok := find(activeOf(h.target), name)
	if !ok {
		panic(name + " is not a trigger of " + h.target)
	}
	removeIDs(h.target, id)
}

// mustHold panics unless h is its realm's live handle and caller is that
// realm's gnotif identity.
func (h *Handle) mustHold(caller string) {
	if handles.Get(h.target) != h {
		panic("not the live handle of " + h.target)
	}
	if caller != h.target+"#"+Subpath {
		panic("not the gnotif identity of " + h.target + ": " + caller)
	}
}

// Drop removes target's listed active triggers, ids separated by commas.
// Spaces around an id are ignored. Only target's namespace owner may call it,
// directly, with their own key. r/sys/names says who the owner is, and while
// it is not enabled nobody is. A call that lists an id more than once, or one
// that is not an active trigger of target, removes nothing. Drop leaves the realm's handle live: Revoke stops the realm
// from setting them again.
func Drop(cur realm, target, ids string) {
	mustOwn(cur, target)
	live := make(map[string]bool)
	for _, id := range activeOf(target) {
		live[id] = true
	}
	dropped := strings.Split(ids, ",")
	for i, id := range dropped {
		id = strings.TrimSpace(id)
		dropped[i] = id
		if !live[id] {
			panic(id + " is not an active trigger of " + target)
		}
		live[id] = false
	}
	removeIDs(target, dropped...)
}

// Revoke ends target's handle: its methods panic from then on, and target's
// triggers stay. The realm can Open a new handle. Only target's namespace
// owner may call it, directly, with their own key. r/sys/names says who the
// owner is, and while it is not enabled nobody is.
func Revoke(cur realm, target string) {
	mustOwn(cur, target)
	if _, removed := handles.Remove(target); !removed {
		panic(target + " holds no handle")
	}
}

// Active lists target's active trigger ids, comma-separated, oldest first.
func Active(target string) string {
	return strings.Join(activeOf(target), ",")
}

func activeOf(target string) []string {
	ids, _ := byTarget.Get(target).([]string)
	return ids
}

// ceiling: decodes up to maxPerTarget records per lookup; index target and
// name to id before raising maxPerTarget.
func find(ids []string, name string) (string, record, bool) {
	for _, id := range ids {
		if r := decodeRecord(triggers.Get(id)); r.Name == name {
			return id, r, true
		}
	}
	return "", record{}, false
}

// targetOf returns the realm whose gnotif identity me is, and panics for any
// other caller.
func targetOf(_ int, me realm) string {
	path := me.PkgPath()
	host, subpath, _ := chain.SplitPkgSubPath(path)
	if subpath != Subpath || !validTarget(host) {
		panic("call with this realm's gnotif identity (me := cur.Sub(gnotif.Subpath), then cross(me)); got " + path)
	}
	return host
}

// mustOwnerEntered panics unless target's namespace owner signed the
// transaction with its own key and called target's realm directly.
func mustOwnerEntered(_ int, me realm, target string) {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("signed with a session key: sign with the namespace owner's own key")
	}
	signer := unsafe.OriginCaller()
	if ns := namespaceOf(target); !names.IsAuthorizedAddressForNamespace(signer, ns) {
		panic(signer.String() + " is not authorized for namespace " + ns)
	}
	// The Previous of a gnotif identity is the caller of its host realm.
	entry := me.Previous()
	if !entry.IsUserCall() || entry.Address() != signer {
		panic("the dapp was not entered directly by its namespace owner; entered from " + entry.PkgPath())
	}
}

// mustOwn panics unless target's namespace owner called straight into the
// registry with its own key.
func mustOwn(cur realm, target string) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("only the namespace owner may do this, in a call signed with its own key; got " + caller.PkgPath())
	}
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("sign with the namespace owner's own key, not a session key")
	}
	// Before Enable, names authorizes every key for every namespace.
	if !names.IsEnabled() {
		panic("r/sys/names is not enabled, so no namespace has an owner")
	}
	if ns := namespaceOf(target); !names.IsAuthorizedAddressForNamespace(caller.Address(), ns) {
		panic(caller.Address().String() + " is not authorized for namespace " + ns)
	}
}

// store writes r under id and emits TriggerDeclared.
func store(id string, r record, approver string) {
	triggers.Set(id, r.encode())
	chain.Emit("TriggerDeclared",
		"id", id,
		"target", r.Target,
		"name", r.Name,
		"event", r.T.Event,
		"filter", r.T.Filter,
		"param", r.T.Param,
		"title", r.T.Title,
		"body", r.T.Body,
		"link", r.T.Link,
		"declarer", chain.PackageAddress(r.Target).String(),
		"verified", "true",
		"approver", approver,
	)
}

// removeIDs removes the listed active ids of target and emits TriggerRemoved
// for each.
func removeIDs(target string, ids ...string) {
	gone := make(map[string]bool, len(ids))
	for _, id := range ids {
		gone[id] = true
	}
	var left []string
	for _, id := range activeOf(target) {
		if !gone[id] {
			left = append(left, id)
		}
	}
	if len(left) == 0 {
		byTarget.Remove(target)
	} else {
		byTarget.Set(target, left)
	}
	for _, id := range ids {
		triggers.Remove(id)
		chain.Emit("TriggerRemoved", "id", id)
	}
}
