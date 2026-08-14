package throwawaytestadapter

// Debug-only: wraps testcollectionv2 the exact same way gemsg7adapterv3
// wraps g7, to isolate whether List()'s approval check works correctly
// when reached through a real adapter (interface dispatch from
// nftmarketv2 into this package) rather than a native registration —
// never verified end-to-end before, only via direct qeval on the
// adapter's own path. Not part of the checked-in app.

import (
	unsaferealm "chain/runtime/unsafe"

	market "gno.land/p/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/market"
	target "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/testcollectionv2"
	nftmarket "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/nftmarketv2"
)

func Name() string                        { return target.Name() }
func OwnerOf(tid string) (address, error) { return target.OwnerOf(tid) }
func TokenURI(tid string) (string, error) { return target.TokenURI(tid) }

func GetApproved(tid string) (address, error) {
	approved, err := target.GetApproved(tid)
	if err != nil {
		return "", nil
	}
	return approved, nil
}

func IsApprovedForAll(owner, operator address) bool {
	return target.IsApprovedForAll(owner, unsaferealm.CurrentRealm().Address())
}

func ApprovalTarget() string    { return "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/testcollectionv2" }
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
