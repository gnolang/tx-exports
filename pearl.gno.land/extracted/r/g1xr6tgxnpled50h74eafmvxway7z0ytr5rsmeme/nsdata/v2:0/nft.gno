package nsdata

import (
	"strings"
	"time"

	"gno.land/p/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/grc721"
)

func isTokenValid(tid string) bool {
	if strings.HasPrefix(tid, "*") {
		d, ok := getDomain(tid[1:])
		return ok && isValidNow(d.expires, time.Now().Unix())
	}
	label, domainLabel := splitTokenID(tid)
	n, ok := getName(label, domainLabel)
	return ok && isValidNow(n.expires, time.Now().Unix())
}

func BalanceOf(owner address) int64 {
	bal, err := nft.BalanceOf(owner)
	if err != nil {
		panic(err)
	}
	return bal
}

// OwnerOf hides the owner of an expired token — the anti-scam pattern,
// so a lapsed name cannot be listed for sale anywhere. The real owner
// stays tracked in the record itself, so renewal still works.
func OwnerOf(tid grc721.TokenID) address {
	owner, err := nft.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	if !isTokenValid(string(tid)) {
		panic("nsdata: token is expired, no current owner")
	}
	return owner
}

/*
GetApproved answers "who may move this token", and answers it TOTALLY.

The vendored BasicNFT returns an error for a token with no per-token
approval, and this used to turn that into a panic — so "nobody has
approved anyone" was indistinguishable from "no such token", and any
caller that wanted to fall back to the operator grant could not, because
the panic came first. nsmarket hit exactly that: a seller who granted
SetApprovalForAll and listed a name got a raw vault panic, and the
marketplace comment claiming either form of permission counts was false.

The zero address means no approval. An unknown token id still panics,
because that is a caller error rather than an answer. A read that a
caller cannot ask safely is a read that pushes every caller into
guessing, and this realm cannot be redeployed to soften it later.
*/
func GetApproved(tid grc721.TokenID) address {
	addr, err := nft.GetApproved(tid)
	if err != nil {
		// Distinguish "nobody is approved" from "no such token" by the
		// only total question the vendored NFT offers: who owns it.
		if _, oerr := nft.OwnerOf(tid); oerr != nil {
			panic(err)
		}
		return ""
	}
	return addr
}

// IsApprovedFor is the question a marketplace actually has: may this
// operator move this token, by either route? Exposed so callers stop
// reimplementing the two-step and getting the order wrong.
func IsApprovedFor(tid grc721.TokenID, operator address) bool {
	owner, err := nft.OwnerOf(tid)
	if err != nil {
		return false
	}
	if owner == operator {
		return true
	}
	if nft.IsApprovedForAll(owner, operator) {
		return true
	}
	a, aerr := nft.GetApproved(tid)
	return aerr == nil && a == operator
}

func IsApprovedForAll(owner, operator address) bool {
	return nft.IsApprovedForAll(owner, operator)
}

// TokenURI returns a pointer at whichever view realm currently renders
// the artwork, rather than generating it here.
//
// The generator used to live in this realm, which meant the NFT art —
// the most cosmetic, most likely-to-be-revised thing in the whole
// system — was frozen forever the moment the vault deployed. It is now
// a settable prefix (SetTokenURIBaseRecord), so the art can be
// redesigned, or moved to a different renderer entirely, without
// touching the one realm that cannot be replaced.
func TokenURI(tid grc721.TokenID) string {
	return tokenURIBase + string(tid)
}
