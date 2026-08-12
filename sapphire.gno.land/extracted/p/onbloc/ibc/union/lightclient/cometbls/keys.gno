package cometbls

import (
	"strconv"
	"strings"

	"gno.land/p/onbloc/ibc/union/types"
)

const (
	ModuleName = "cometbls"

	ClientType = ModuleName
)

var moduleKey = []byte("wasm")

func makeStoreKey(addr types.H256, key []byte) []byte {
	out := make([]byte, 0, 1+32+1+len(key))
	out = append(out, 0x03)
	out = append(out, addr[:]...)
	out = append(out, 0x00)
	out = append(out, key...)

	return out
}

// heightKey renders a height as a fixed-width, lexicographically sortable bptree
// key. CometBLS uses a single revision, so the revision-height ordering matches
// numeric ordering.
func heightKey(height types.Height) string {
	return zeroPadDecimalUint64(height.RevisionNumber) + "-" + zeroPadDecimalUint64(height.RevisionHeight)
}

// zeroPadDecimalUint64 converts a uint64 number into a zero-padded 20-character string.
//
// num (uint64): The number to encode.
//
// Returns:
// A zero-padded string representation of the number.
func zeroPadDecimalUint64(num uint64) string {
	// Convert the value to a decimal string.
	s := strconv.FormatUint(num, 10)

	// Zero-pad to a total length of 20 characters.
	zerosNeeded := 20 - len(s)

	return strings.Repeat("0", zerosNeeded) + s
}
