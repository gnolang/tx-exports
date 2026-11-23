// Package questboard is a dummy source realm used by Barkeep tests.
package questboard

import "gno.land/r/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/barkeep/v0"

var completed int

func init(cur realm) {
	barkeep.RegisterSource(cross(cur), "contribution", "Quests for adventurers")
}

// Complete marks a quest done and attests the caller in Barkeep.
func Complete(cur realm, id string) bool {
	completed++
	return barkeep.Attest(cross(cur), cur.Previous().Address(), "quest.completed", 10)
}

// Completed returns how many quests were completed.
func Completed() int { return completed }
