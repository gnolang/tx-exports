package memba_appstore_v3

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

func IsPaused() bool        { return paused }
func IsSeedingSealed() bool { return seedingSealed }

// Scalars only: no persistent Listing pointer or screenshot slice escapes.
type GovernanceListing struct {
	Exists                      bool
	ContentHash, Status, Reason string
	Credit                      bool
	Flags                       int
	ClearKeys                   string
}

func GetGovernanceListing(pkgPath string, clearBatch bool) GovernanceListing {
	v, ok := listings.Get(pkgPath)
	if !ok {
		return GovernanceListing{}
	}
	l := v.(*Listing)
	snapshot := *l
	snapshot.Status = ""
	snapshot.RejectReason = ""
	snapshot.PaidResubmitCredit = false
	snapshot.FlagCount = 0
	digest := sha256.Sum256([]byte(listingJSON(&snapshot, true)))
	s := GovernanceListing{Exists: true, ContentHash: hex.EncodeToString(digest[:]), Status: l.Status, Reason: l.RejectReason, Credit: l.PaidResubmitCredit, Flags: l.FlagCount}
	if clearBatch {
		keys := []string{}
		flaggedBy.Iterate(pkgPath+"\x00", pkgPath+"\x01", func(k string, _ any) bool {
			keys = append(keys, strings.TrimPrefix(k, pkgPath+"\x00"))
			return len(keys) >= MaxClearBatch
		})
		s.ClearKeys = strings.Join(keys, ",")
	}
	return s
}
func HasGovernanceFlag(pkgPath, who string) bool {
	_, ok := flaggedBy.Get(pkgPath + "\x00" + who)
	return ok
}
