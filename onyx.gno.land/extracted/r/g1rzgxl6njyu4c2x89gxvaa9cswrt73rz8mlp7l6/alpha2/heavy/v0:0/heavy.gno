// Package heavy emits events at the chain's size limits, so one transaction's
// indexer answer can exceed gnotifd's 64 MiB read limit.
package heavy

import (
	"chain"
	"strconv"
	"strings"
)

// The chain caps an event at 64 attribute pairs, and each key and value at
// 4,096 bytes.
const (
	pairs   = 64
	attrLen = 4096
)

// Emit emits n events, each with every attribute pair at its maximum size.
func Emit(_ realm, n int) {
	attrs := make([]string, 0, 2*pairs)
	value := strings.Repeat("v", attrLen)
	for i := 0; i < pairs; i++ {
		prefix := strconv.Itoa(i) + "-"
		attrs = append(attrs, prefix+strings.Repeat("k", attrLen-len(prefix)), value)
	}
	for i := 0; i < n; i++ {
		chain.Emit("Heavy", attrs...)
	}
}

// EventBytes is the size of one event's keys and values.
func EventBytes() int {
	return 2 * pairs * attrLen
}
