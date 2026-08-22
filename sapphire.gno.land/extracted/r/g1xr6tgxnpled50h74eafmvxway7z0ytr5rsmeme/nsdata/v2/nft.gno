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

func GetApproved(tid grc721.TokenID) address {
	addr, err := nft.GetApproved(tid)
	if err != nil {
		panic(err)
	}
	return addr
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
