package hearthregistry

// HearthRegistry is the demo execution target for HearthCouncil: a tiny
// on-chain parameter store. It proves that a passed DAO proposal can
// change state in another realm.
//
// Only the HearthCouncil DAO realm may write (checked by package path of
// the calling realm). Reads are open to everyone.

import (
	"chain"

	"gno.land/p/nt/avl/v0"
)

// daoPkgPath is the only realm allowed to change parameters.
const daoPkgPath = "gno.land/r/g1utqjz9adrhy5y26hfufgqyua0srsxwkf776vzd/hearthcouncil"

var params avl.Tree // key string -> value string

func init(cur realm) {
	params.Set("greeting", "Welcome to HearthCouncil")
	params.Set("max_proposals_per_day", "10")
	params.Set("tavern_name", "The Hearth Tavern")
}

// GetParam returns the value for key, or "" if unset.
func GetParam(key string) string {
	v := params.Get(key)
	if v == nil {
		return ""
	}
	return v.(string)
}

// HasParam reports whether key exists.
func HasParam(key string) bool {
	return params.Has(key)
}

// ParamCount returns the number of stored parameters.
func ParamCount() int {
	return params.Size()
}

// SetParam writes a parameter. Only callable by the HearthCouncil DAO
// realm (a cross-realm call from the DAO after a passed proposal).
func SetParam(cur realm, key, value string) {
	if cur.Previous().PkgPath() != daoPkgPath {
		panic("only the HearthCouncil DAO can set parameters")
	}
	if key == "" {
		panic("key must not be empty")
	}
	params.Set(key, value)
	chain.Emit("ParamSet", "key", key, "value", value)
}

// Keys returns all parameter keys in sorted order (for Render).
func Keys() []string {
	keys := []string{}
	params.Iterate("", "", func(key string, value any) bool {
		keys = append(keys, key)
		return false // keep iterating
	})
	return keys
}
