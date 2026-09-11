package nsdata

import (
	"time"

	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsnft/v1"
)

/*
The token reads, answered by the ledger.

These used to be the vault's own grc721 state. They are now read-throughs
to nsnft, kept here under the same names so nsview, nsskin, nsvote and
the site can go on asking the registry — while an external marketplace
asks nsnft directly and gets the identical answer, because there is only
one ledger to ask.

Token ids here are plain strings. The grc721.TokenID type was the vault's
import; this realm no longer imports grc721 at all.
*/

func isTokenValid(tid string) bool {
	label, domainLabel := splitTokenID(tid)
	n, ok := getName(label, domainLabel)
	return ok && isValidNow(n.expires, time.Now().Unix())
}

// BalanceOf counts every token an address holds — including free-tier
// tokens, which are held rather than absent. That is a real change from
// the previous generation, where a free name had no token and counted
// for nothing; nsvote gates on this, so free-tier holders now have a vote.
func BalanceOf(owner address) int64 { return nsnft.BalanceOf(owner) }

// OwnerOf hides the owner of an expired token — the anti-scam pattern,
// so our own pages never present a lapsed name as somebody's. nsnft
// itself answers regardless; see MIGRATION.md, rule 6.
func OwnerOf(tid string) address {
	owner := nsnft.OwnerOf(tid)
	if owner == "" {
		panic("nsdata: no such token: " + tid)
	}
	if !isTokenValid(tid) {
		panic("nsdata: token is expired, no current owner")
	}
	return owner
}

// GetApproved answers totally: the zero address means nobody is approved
// or there is no such token. See the long note this replaced in git
// history for why a panic here broke the marketplace once already.
func GetApproved(tid string) address { return nsnft.GetApproved(tid) }

// IsApprovedFor is the question a marketplace actually has: may this
// operator move this token, by either route?
func IsApprovedFor(tid string, operator address) bool {
	owner := nsnft.OwnerOf(tid)
	if owner == "" {
		return false
	}
	if owner == operator || nsnft.IsApprovedForAll(owner, operator) {
		return true
	}
	return nsnft.GetApproved(tid) == operator
}

func IsApprovedForAll(owner, operator address) bool {
	return nsnft.IsApprovedForAll(owner, operator)
}

// TokenURI returns a pointer at whichever view realm renders the art.
// nsnft has its own URI base for external marketplaces; both are set to
// the same view realm at wiring time.
func TokenURI(tid string) string {
	return tokenURIBase + tid
}
