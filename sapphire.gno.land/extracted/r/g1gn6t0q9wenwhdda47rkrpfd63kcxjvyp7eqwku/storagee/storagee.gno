// Package storagee measures the cheapest useful thing this project could
// store: one small entry in a tree, keyed by a composite string.
//
// That is the shape of BOTH a vote ("proposal:voter" -> when) and a
// grant ("address" -> the name they may claim free). Neither needs a
// struct, a timestamp object or a nested tree, so both should cost far
// less than a name record -- but "should" is not a number, and the point
// of asking what a vote costs is to get a number.
package storagee

import (
	"gno.land/p/nt/avl/v0"
)

var entries avl.Tree

// Set stores one entry. The value is a short string, which is all a vote
// or a grant actually needs.
func Set(cur realm, key, value string) {
	entries.Set(key, value)
}

func Count() int { return entries.Size() }
