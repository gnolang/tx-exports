package bolo

import (
	"strconv"

	"gno.land/p/nt/seqid/v0"
)

// parseID returns the campaign ID s names, if s is canonical (API C9): the
// decimal form of a positive ID — digits only, no sign, no leading zero, no
// space. "042" names nothing, never campaign 42: one ID has one spelling, and so
// one set of addresses (INV-18).
func parseID(s string) (seqid.ID, bool) {
	if len(s) == 0 || len(s) > 20 || s[0] == '0' {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0, false
	}
	return seqid.ID(n), true
}

// idString is the canonical decimal form of id.
func idString(id seqid.ID) string {
	return strconv.FormatUint(uint64(id), 10)
}
