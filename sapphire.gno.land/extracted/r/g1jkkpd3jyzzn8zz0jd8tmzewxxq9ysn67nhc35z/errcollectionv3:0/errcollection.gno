package errcollectionv3

// Debug-only: same as errcollectionv2 (faithfully replicates g7's real
// GetApproved-errors-when-empty behavior + avl.Tree storage), but
// self-registers NATIVELY with nftmarketv2 — no adapter layer at all —
// to isolate whether the adapter/interface-dispatch layer is involved in
// the bug, or whether it's purely about GetApproved erroring.

import (
	"errors"

	"gno.land/p/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/market"
	"gno.land/p/nt/avl/v0"
	nftmarket "gno.land/r/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/nftmarketv2"
)

var (
	owners            = avl.NewTree() // tid -> address
	operatorApprovals = avl.NewTree() // "owner|operator" -> bool
)

var errNoApproval = errors.New("token id not approved for anyone")

func Name() string { return "ErrCollectionV3" }

func Mint(cur realm, to address, tid string) {
	owners.Set(tid, to)
}

func OwnerOf(tid string) (address, error) {
	owner, _ := owners.Get(tid).(address)
	return owner, nil
}

func TokenURI(tid string) (string, error) {
	return "", nil
}

func GetApproved(tid string) (address, error) {
	return "", errNoApproval
}

func operatorKey(owner, operator address) string {
	return owner.String() + "|" + operator.String()
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	caller := cur.Previous().Address()
	key := operatorKey(caller, operator)
	if approved {
		operatorApprovals.Set(key, true)
	} else {
		operatorApprovals.Remove(key)
	}
}

func IsApprovedForAll(owner, operator address) bool {
	return operatorApprovals.Has(operatorKey(owner, operator))
}

func TransferFrom(cur realm, from, to address, tid string) error {
	caller := cur.Previous().Address()
	owner, _ := owners.Get(tid).(address)
	if caller != owner && !IsApprovedForAll(owner, caller) {
		return errors.New("not authorized")
	}
	owners.Set(tid, to)
	return nil
}

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
	return TransferFrom(cur, from, to, tid)
}

var _ market.NFT = marketAdapter{}

func RegisterWithMarketplace(cur realm) string {
	return nftmarket.RegisterCollection(cross(cur), marketAdapter{})
}
