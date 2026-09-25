package nft

import "gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/grc721/v0"

// Token returns the collection as a read-only GRC721 teller.
func Token() grc721.Teller { return collection.ReadonlyTeller() }

// GetName returns the name of the collection.
func GetName() string { return collection.GetName() }

// GetSymbol returns the symbol of the collection.
func GetSymbol() string { return collection.GetSymbol() }

// ID returns the ID of the collection.
func ID() string { return collection.ID() }

// TotalSupply returns the number of Settlers minted so far.
func TotalSupply() int64 { return collection.TotalSupply() }

// BalanceOf returns the number of Settlers of an account, 0 or 1.
func BalanceOf(owner address) (int64, error) { return collection.BalanceOf(owner) }

// OwnerOf returns the owner account of a Settler.
func OwnerOf(tid grc721.TokenID) (address, error) { return collection.OwnerOf(tid) }

// GetApproved returns the account allowed to move a Settler on behalf of its owner.
// Settlers are soulbound, so it always fails.
func GetApproved(tid grc721.TokenID) (address, error) { return collection.GetApproved(tid) }

// IsApprovedForAll reports whether an account is allowed to move the Settler of another account.
// Settlers are soulbound, so it is always false.
func IsApprovedForAll(owner, operator address) bool {
	return collection.IsApprovedForAll(owner, operator)
}

// Approve always fails, Settlers are soulbound.
func Approve(cur realm, to address, tid grc721.TokenID) { panic(ErrSoulbound) }

// SetApprovalForAll always fails, Settlers are soulbound.
func SetApprovalForAll(cur realm, operator address, approved bool) { panic(ErrSoulbound) }

// TransferFrom always fails, Settlers are soulbound.
func TransferFrom(cur realm, from, to address, tid grc721.TokenID) { panic(ErrSoulbound) }
