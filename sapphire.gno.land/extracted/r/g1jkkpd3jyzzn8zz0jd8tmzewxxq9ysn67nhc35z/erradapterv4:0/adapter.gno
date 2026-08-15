package erradapterv4

// Debug-only: wraps errcollection (which faithfully replicates g7's real
// GetApproved-errors-when-empty behavior) the exact same way
// gemsg7adapterv3 wraps g7 — this is the missing, more faithful
// reproduction of the real bug that throwawaytestadapter (wrapping
// testcollectionv2, which never errors on GetApproved) didn't actually
// exercise.

import (
	unsaferealm "chain/runtime/unsafe"

	market "gno.land/p/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/market"
	target "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/errcollectionv4"
	nftmarket "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/nftmarketv2"
)

func Name() string                        { return target.Name() }
func OwnerOf(tid string) (address, error) { return target.OwnerOf(tid) }
func TokenURI(tid string) (string, error) { return target.TokenURI(tid) }

// Deliberately never calls target.GetApproved at all — only
// SetApprovalForAll is ever used through this marketplace, so per-token
// approval is never relevant, and calling into target's own GetApproved
// (which errors when nothing is individually approved, like g7's real
// implementation) is what triggers the qeval-vs-real-execution
// discrepancy under test.
func GetApproved(tid string) (address, error) {
	return "", nil
}

func IsApprovedForAll(owner, operator address) bool {
	return target.IsApprovedForAll(owner, unsaferealm.CurrentRealm().Address())
}

func ApprovalTarget() string    { return "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/errcollectionv4" }
func ApprovalOperator() address { return unsaferealm.CurrentRealm().Address() }

type marketAdapter struct{}

func (marketAdapter) Name() string                        { return Name() }
func (marketAdapter) OwnerOf(tid string) (address, error) { return OwnerOf(tid) }
func (marketAdapter) TokenURI(tid string) (string, error) { return TokenURI(tid) }
func (marketAdapter) GetApproved(tid string) (address, error) {
	return GetApproved(tid)
}
func (marketAdapter) IsApprovedForAll(owner, operator address) bool {
	return IsApprovedForAll(owner, operator)
}
func (marketAdapter) TransferFrom(cur realm, from, to address, tid string) error {
	target.TransferFrom(cross(cur), from, to, tid)
	return nil
}

var _ market.NFT = marketAdapter{}

func RegisterWithMarketplace(cur realm) string {
	return nftmarket.RegisterCollection(cross(cur), marketAdapter{})
}
