// Package ping is a minimal counter for checking wallet signing: anyone may
// call Ping, which adds one to the count and records who called.
package ping

import (
	"strconv"
)

var (
	count      int
	lastCaller address
)

// Ping adds one to the count and records the caller.
func Ping(cur realm) {
	count++
	lastCaller = cur.Previous().Address()
}

// Count is the number of pings so far.
func Count() int {
	return count
}

func Render(_ string) string {
	if count == 0 {
		return "# Ping\n\nNo pings yet.\n"
	}
	return "# Ping\n\nPings: " + strconv.Itoa(count) + "\n\nLast caller: " + lastCaller.String() + "\n"
}
