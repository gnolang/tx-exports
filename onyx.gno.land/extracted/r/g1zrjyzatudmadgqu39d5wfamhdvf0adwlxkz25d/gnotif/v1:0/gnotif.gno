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

	"gno.land/p/g1zrjyzatudmadgqu39d5wfamhdvf0adwlxkz25d/gnotif/trigger/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/sys/names"
)

// Subpath is the subpath of a realm's gnotif identity: me := cur.Sub(gnotif.Subpath).
const Subpath = "gnotif"

// Trigger is an alias, so a dapp imports only the registry.
type Trigger = trigger.Trigger

var (
	triggers bptree.BPTree // id → record.encode()
	// byTarget maps a target to its active ids, oldest first. The entry
	// stays once set, even with no ids left, and marks the target as set.
	byTarget bptree.BPTree
	lastID   seqid.ID
)

// Declare activates ts for the realm whose gnotif identity calls it and
// returns their ids in order. Only the realm's first activating call can add
// triggers, and only when the realm's namespace owner signed the transaction
// and sent it straight to the realm. A later call must list every active
// trigger.
func Declare(cur realm, ts ...Trigger) []string {
	me := cur.Previous()
	target := targetOf(0, me)
	if len(ts) == 0 {
		panic("declare at least one trigger")
	}
	for _, t := range ts {
		validate(t)
	}
	active, set := activeOf(target)
	idOf := make(map[Trigger]string, len(active))
	for _, id := range active {
		idOf[decodeRecord(triggers.Get(id)).T] = id
	}
	ids := make([]string, len(ts))
	first := make(map[Trigger]int) // index in ts of each new trigger's first copy
	named := make(map[string]bool, len(active))
	for i, t := range ts {
		if id, ok := idOf[t]; ok {
			ids[i] = id
			named[id] = true
		} else if _, ok := first[t]; !ok {
			first[t] = i
		}
	}
	// A list that leaves out an active trigger reaches the panic below, so code
	// that declared first cannot hide an extra trigger behind the realm's list.
	if len(first) == 0 && len(named) == len(active) {
		return ids
	}
	if set {
		panic("the triggers of " + target + " are set: deploy a new version of the realm to change them")
	}
	mustOwnerEntered(0, me, target)
	if len(active)+len(first) > maxPerTarget {
		panic("too many triggers for target")
	}
	approver := unsafe.OriginCaller().String()
	for i, t := range ts {
		if ids[i] != "" {
			continue
		}
		if j := first[t]; j < i {
			ids[i] = ids[j]
			continue
		}
		ids[i] = add(target, t, approver)
		active = append(active, ids[i])
	}
	byTarget.Set(target, active)
	return ids
}

// Drop removes target's listed active triggers, ids separated by commas, for
// good. Spaces around an id are ignored. Only target's namespace owner may
// call it, directly, with their own key. A call that lists an id more than
// once, or one that is not an active trigger of target, removes nothing. The
// target stays set: its realm cannot declare again.
func Drop(cur realm, target, ids string) {
	mustOwn(cur, target)
	active, _ := activeOf(target)
	live := make(map[string]bool, len(active))
	for _, id := range active {
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
	// left stays a nil []string when no id is left: its type marks the target
	// as set, and a zero-length non-nil slice would keep its last array stored.
	var left []string
	for _, id := range active {
		if live[id] {
			left = append(left, id)
		}
	}
	byTarget.Set(target, left)
	for _, id := range dropped {
		triggers.Remove(id)
		chain.Emit("TriggerRemoved", "id", id)
	}
}

// Active lists target's active trigger ids, comma-separated, oldest first.
func Active(target string) string {
	ids, _ := activeOf(target)
	return strings.Join(ids, ",")
}

func activeOf(target string) (ids []string, set bool) {
	ids, set = byTarget.Get(target).([]string)
	return ids, set
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
	if ns := namespaceOf(target); !names.IsAuthorizedAddressForNamespace(caller.Address(), ns) {
		panic(caller.Address().String() + " is not authorized for namespace " + ns)
	}
}

// add stores t under a new id and emits TriggerDeclared. The caller lists the
// id under target in byTarget.
func add(target string, t Trigger, approver string) string {
	id := "v1-" + lastID.Next().String()
	triggers.Set(id, record{Target: target, T: t}.encode())
	chain.Emit("TriggerDeclared",
		"id", id,
		"target", target,
		"event", t.Event,
		"filter", t.Filter,
		"param", t.Param,
		"title", t.Title,
		"body", t.Body,
		"link", t.Link,
		"declarer", chain.PackageAddress(target).String(),
		"verified", "true",
		"approver", approver,
	)
	return id
}
