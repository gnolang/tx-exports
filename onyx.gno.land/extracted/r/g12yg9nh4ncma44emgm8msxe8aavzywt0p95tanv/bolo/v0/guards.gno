package bolo

import (
	"math"
	"time"
)

// assertCurrent is the first statement of every crossing function (API C2).
func assertCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("bolo: not the current realm")
	}
}

// checkAddress refuses an address argument that isn't a well-formed address (API
// C12): exactly 40 characters, a lowercase "g" first, then IsValid(). MsgCall
// passes an address argument through unchecked, and a malformed one stored once
// would make every later send to it fail. IsValid alone also accepts an address in
// capitals, which the bank pays as the same account but which never equals the
// lowercase spelling; it refuses mixed case, so a lowercase "g" means a lowercase
// address. The length comes first, so IsValid only ever parses address-sized
// input.
func checkAddress(a address, err Error) {
	if len(a) != 40 || a[0] != 'g' || !a.IsValid() {
		panic(err)
	}
}

const secondsPerDay = 24 * 60 * 60

// daysToSeconds converts a duration in whole days to seconds, refusing a negative
// one and one whose seconds would overflow (API §2.3).
func daysToSeconds(days int, err Error) int64 {
	if days < 0 || int64(days) > math.MaxInt64/secondsPerDay {
		panic(err)
	}
	return int64(days) * secondsPerDay
}

// now is block time in Unix seconds (API C8).
func now() int64 { return time.Now().Unix() }
