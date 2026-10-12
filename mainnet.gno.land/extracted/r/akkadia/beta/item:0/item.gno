package item

import (
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/akkadia/beta/grc1155"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/akkadia/beta/admin"
)

const (
	maxInt64 = int64(9223372036854775807)
)

var (
	itemToken     = grc1155.NewBasicGRC1155Token("")
	itemSupplies  *bptree.BPTree
	ownerTokenIDs *bptree.BPTree
)

func init() { resetItemState() }

func resetItemState() {
	itemToken = grc1155.NewBasicGRC1155Token("")
	itemSupplies = bptree.NewBPTree32()
	ownerTokenIDs = bptree.NewBPTree32()
	minterRealms = bptree.NewBPTree32()
	listLimit = 100
}

func SafeMint(cur realm, recipient address, tokenID string, amount int64) {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertItemNoCoins()
	mintItem(cross(cur), executor, recipient, tokenID, amount)
}

func SafeMintFromRealm(cur realm, recipient address, tokenID string, amount int64) {
	executor := mustGetMinterRealmCaller(0, cur)
	if unsafe.OriginCaller() != recipient {
		panic("item recipient must be origin caller")
	}
	mintItem(cross(cur), executor, recipient, tokenID, amount)
}

func Uri() string { return itemToken.Uri() }
func IsApprovedForAll(owner, operator address) bool {
	return itemToken.IsApprovedForAll(owner, operator)
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertItemNoCoins()
	if err := itemToken.SetApprovalForAll(caller, operator, approved); err != nil {
		panic("item operator approval failed: " + err.Error())
	}
}

func SafeTransferFrom(cur realm, from, to address, tokenID string, amount int64) {
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertItemNoCoins()
	assertItemTokenID(tokenID)
	assertItemAmount(amount, "transfer")
	if err := itemToken.SafeTransferFrom(caller, from, to, grc1155.TokenID(tokenID), amount); err != nil {
		panic("item transfer failed: " + err.Error())
	}
	if from != to {
		addOwnerTokenID(to, tokenID)
		if BalanceOf(from, tokenID) == 0 {
			removeOwnerTokenID(from, tokenID)
		}
	}
}

func BalanceOf(owner address, tokenID string) int64 {
	if !owner.IsValid() {
		panic("invalid item owner")
	}
	assertItemTokenID(tokenID)
	balance, err := itemToken.BalanceOf(owner, grc1155.TokenID(tokenID))
	if err != nil {
		panic("item balance query failed: " + err.Error())
	}
	return balance
}

func TotalSupply(tokenID string) int64 {
	assertItemTokenID(tokenID)
	value := itemSupplies.Get(tokenID)
	if value == nil {
		return 0
	}
	return value.(int64)
}

func GetOwnedCount(owner address) int {
	if !owner.IsValid() {
		panic("invalid item owner")
	}
	ids, found := getOwnerTokenIDs(owner)
	if !found {
		return 0
	}
	return ids.Size()
}

func ListByOwner(owner address, page, count int) []map[string]string {
	if !owner.IsValid() {
		panic("invalid item owner")
	}
	assertItemListPageCount(page, count)
	ids, found := getOwnerTokenIDs(owner)
	if !found {
		return []map[string]string{}
	}
	result := []map[string]string{}
	ids.IterateByOffset((page-1)*count, count, func(tokenID string, _ any) bool {
		result = append(result, map[string]string{
			"tokenId": tokenID,
			"amount":  strconv.FormatInt(BalanceOf(owner, tokenID), 10),
		})
		return false
	})
	return result
}

func Burn(cur realm, from address, tokenID string, amount int64) {
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertItemNoCoins()
	assertItemTokenID(tokenID)
	if caller != from && !itemToken.IsApprovedForAll(from, caller) {
		panic("item owner or approved operator required")
	}
	assertItemAmount(amount, "burn")
	burnItem(cross(cur), caller, from, tokenID, amount)
}

func BurnFromRealm(cur realm, from address, tokenID string, amount int64) {
	caller := mustGetMinterRealmCaller(0, cur)
	if unsafe.OriginCaller() != from {
		panic("item owner must be origin caller")
	}
	assertItemTokenID(tokenID)
	assertItemAmount(amount, "burn")
	burnItem(cross(cur), caller, from, tokenID, amount)
}

func mintItem(cur realm, executor, recipient address, tokenID string, amount int64) {
	assertItemTokenID(tokenID)
	if !recipient.IsValid() || recipient == cur.Address() {
		panic("invalid item recipient")
	}
	if amount <= 0 {
		panic("item amount must be positive")
	}
	supply := TotalSupply(tokenID)
	if supply > maxInt64-amount {
		panic("item amount overflow")
	}
	if err := itemToken.SafeMint(executor, recipient, grc1155.TokenID(tokenID), amount); err != nil {
		panic("item mint failed: " + err.Error())
	}
	itemSupplies.Set(tokenID, supply+amount)
	addOwnerTokenID(recipient, tokenID)
}

func burnItem(cur realm, operator, from address, tokenID string, amount int64) {
	supply := TotalSupply(tokenID)
	if supply < amount {
		panic("item burn amount exceeds supply")
	}
	if err := itemToken.Burn(operator, from, grc1155.TokenID(tokenID), amount); err != nil {
		panic("item burn failed: " + err.Error())
	}
	itemSupplies.Set(tokenID, supply-amount)
	if BalanceOf(from, tokenID) == 0 {
		removeOwnerTokenID(from, tokenID)
	}
}

func mustGetMinterRealmCaller(_ int, rlm realm) address {
	accesscontrol.AssertCurrentRealm(0, rlm)
	prev := rlm.Previous()
	if prev.IsUserCall() {
		panic("user calls not allowed: function must be called by a realm")
	}
	caller := prev.Address()
	if !IsMinterRealm(caller) {
		panic("minter realm required")
	}
	return caller
}

func assertItemNoCoins() {
	if len(unsafe.OriginSend()) != 0 {
		panic("attached coins not allowed")
	}
}

func assertItemTokenID(tokenID string) {
	if tokenID == "" {
		panic("token id is required")
	}
}

func assertItemAmount(amount int64, action string) {
	if amount <= 0 {
		panic("item " + action + " amount must be positive")
	}
}

func assertItemListPageCount(page, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 {
		panic("count must be at least 1")
	}
	if count > listLimit {
		panic("count exceeds listLimit (max: " + strconv.Itoa(listLimit) + ")")
	}
}

func addOwnerTokenID(owner address, tokenID string) {
	value := ownerTokenIDs.Get(owner.String())
	var ids *bptree.BPTree
	if value != nil {
		ids = value.(*bptree.BPTree)
	} else {
		ids = bptree.NewBPTree32()
		ownerTokenIDs.Set(owner.String(), ids)
	}
	ids.Set(tokenID, true)
}

func removeOwnerTokenID(owner address, tokenID string) {
	ids, found := getOwnerTokenIDs(owner)
	if !found {
		return
	}
	ids.Remove(tokenID)
}

func getOwnerTokenIDs(owner address) (*bptree.BPTree, bool) {
	value := ownerTokenIDs.Get(owner.String())
	if value == nil {
		return nil, false
	}
	return value.(*bptree.BPTree), true
}
