package nslogic

import (
	"strings"

	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsdata/v1"
)

// This realm only exposes the WRITE side of the GRC-721 surface. Reads
// (BalanceOf, OwnerOf, TokenURI, GetApproved, IsApprovedForAll, and
// every listing/status/profile query) have no authorization check to
// perform and are served directly by nsdata — no reason to duplicate
// them here.

func isDomainToken(tid string) bool {
	return strings.HasPrefix(tid, "*")
}

// isTokenValid checks the underlying domain/name's expiry via nsdata's
// own validity reads — the anti-scam pattern (an expired name must not
// be sellable) enforced at the transfer boundary, not just at read time.
func isTokenValid(tid string) bool {
	if isDomainToken(tid) {
		return nsdata.IsDomainValid(tid[1:])
	}
	label, domainLabel := splitTokenID(tid)
	return nsdata.IsNameValid(label, domainLabel)
}

// assertNotFrozen is the check that made freezing mean something.
//
// FreezeName set a bit that only ever gated RE-REGISTRATION after a
// lapse. Transfer, approval, listing and sale all ignored it, so the one
// manual lever the takedown process relies on did nothing about the case
// it exists for: a disputed or stolen name could be approved to a fresh
// wallet, listed and sold while the interface showed it as frozen.
//
// The bit was already stored and already readable — GetNameInfo returns
// it — so this needs no change to the permanent vault, only the read
// that was never performed.
func assertNotFrozen(tid string) {
	label, domainLabel := splitTokenID(tid)
	_, _, _, _, frozen, _ := nsdata.GetNameInfo(label, domainLabel)
	if frozen {
		panic("nslogic: this name is frozen and cannot be transferred or approved")
	}
}

/*
THERE ARE NO TRANSFER OR APPROVAL FUNCTIONS HERE ANY MORE.

Approve, SetApprovalForAll, TransferFrom and SafeTransferFrom lived in this
realm, and they could only work while this realm was the one place a
transfer could happen. In this generation ownership is in nsnft, and nsnft
sees whoever calls it as the caller — so a logic realm calling in on a
user's behalf would be refused as not approved, correctly. A logic realm
that COULD move people's tokens would be a logic realm that could steal
them.

So: holders approve and transfer on nsnft directly, and marketplaces —
ours included — settle as approved operators there.

The two policies these wrappers enforced moved to where they bind every
path, not just ours:
  - frozen names: a hold bit on the token in nsnft (nsdata.SetNameFrozen)
  - free-tier names: a hold bit set at mint (nsdata.RegisterNameRecord)
Expired names are refused by our marketplace and never resolve; an
external marketplace can move an expired token, as with any NFT. See
MIGRATION.md, second attempt, rule 6.

The helpers above stay because the marketplace-facing reads use them.
*/
