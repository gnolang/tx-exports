package block

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/grc1155"
	"gno.land/r/akkadia/v0/admin"
)

const (
	MintEvent = "Mint"
)

func BalanceOf(user address, tokenID grc1155.TokenID) int64 {
	assertMigrationStateAvailable()
	return mintedBlockStore.BalanceOf(user, tokenID)
}

func BalanceOfBatch(ul []address, tokenIDs []grc1155.TokenID) []int64 {
	assertMigrationStateAvailable()
	return mintedBlockStore.BalanceOfBatch(ul, tokenIDs)
}

func balanceOfSafe(user address, tokenID grc1155.TokenID) (int64, bool) {
	return mintedBlockStore.BalanceOfSafe(user, tokenID)
}

func IsApprovedForAll(owner, operator address) bool {
	assertMigrationStateAvailable()
	return mintedBlockStore.IsApprovedForAll(owner, operator)
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	mintedBlockStore.SetApprovalForAll(caller, operator, approved)
}

func TransferFrom(cur realm, from, to address, tokenID grc1155.TokenID, amount int64) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	mintedBlockStore.Transfer(caller, from, to, tokenID, amount)
}

func BatchTransferFrom(cur realm, from, to address, tokenIDs []grc1155.TokenID, amounts []int64) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	mintedBlockStore.BatchTransfer(caller, from, to, tokenIDs, amounts)
}

// Mint mints block tokens with payment (anyone can mint)
func Mint(cur realm, to address, blockID uint32, amount int64) {
	assertNotFrozen()

	if amount < 1 {
		panic("amount must be positive")
	}

	caller := accesscontrol.MustGetUserCaller(0, cur)
	if !mintedBlockStore.CanUserMint(blockID, caller) {
		panic("mint not allowed: caller is not the allowed minter")
	}

	block := blockStore.MustGet(blockID)

	maxSupply := mustGetMintableSupply(block)
	if mintedBlockStore.exceedsSupply(blockID, amount, maxSupply) {
		panic("supply exceeded")
	}
	totalMintPrice := mustGetTotalMintPrice(block, amount)

	// MustGetUserCaller guarantees a direct user call, so OriginSend cannot be borrowed through an intermediate realm.
	payment := unsafe.OriginSend().AmountOf("ugnot")
	assertExactPayment(totalMintPrice, payment)

	creatorStr, found := block["creator"]
	if !found {
		panic("creator not found in block: " + block["id"])
	}
	feeCollector := admin.GetFeeCollector()

	tokenID := blockIDToTokenID(blockID)
	mintedBlockStore.Mint(caller, to, tokenID, amount, maxSupply)
	creatorShare, feeCollectorShare := distributeShares(cur, creatorStr, feeCollector, totalMintPrice, creatorBPS)

	chain.Emit(MintEvent,
		"blockId", string(tokenID),
		"amount", strconv.FormatInt(amount, 10),
		"totalPrice", strconv.FormatInt(totalMintPrice, 10),
		"creator", creatorStr,
		"creatorShare", strconv.FormatInt(creatorShare, 10),
		"feeCollector", feeCollector.String(),
		"feeCollectorShare", strconv.FormatInt(feeCollectorShare, 10),
	)
}

func Burn(cur realm, from address, tokenID grc1155.TokenID, amount int64) {
	assertNotFrozen()
	caller := mustGetBurnCaller(0, cur, from)
	mintedBlockStore.Burn(caller, from, tokenID, amount)
}

func BurnBatch(cur realm, from address, tokenIDs []grc1155.TokenID, amounts []int64) {
	assertNotFrozen()
	caller := mustGetBurnCaller(0, cur, from)

	// Burn tokens in one operation
	mintedBlockStore.BatchBurn(caller, from, tokenIDs, amounts)
}

func mustGetBurnCaller(_ int, rlm realm, from address) address {
	caller := accesscontrol.MustGetUserCaller(0, rlm)
	if admin.IsAdmin(caller) {
		return caller
	}
	if caller != from {
		panic("caller must be admin or the user")
	}
	return caller
}

func ListSupplies(tokeIDs ...grc1155.TokenID) []map[string]string {
	assertMigrationStateAvailable()
	return mintedBlockStore.ListSupplies(tokeIDs...)
}

// GetInventory returns all block tokens owned by user with their balances.
func GetInventory(user address) []map[string]string {
	assertMigrationStateAvailable()
	return mintedBlockStore.GetInventory(user)
}

func mustGetMintableSupply(block map[string]string) int64 {
	maxSupply := mustParseInt64(block["maxSupply"])
	if maxSupply == -1 {
		panic("block not mintable")
	}
	return maxSupply
}

func mustGetTotalMintPrice(block map[string]string, amount int64) int64 {
	// mintPrice is a uint32 block property; parse it as uint32 first to preserve
	// the domain bound, then widen to int64 for payment arithmetic.
	mintPrice := int64(mustParseUint32(block["mintPrice"]))
	if mintPrice == 0 || amount == 0 {
		return 0
	}
	if mintPrice > int64(9223372036854775807)/amount {
		panic("mint price overflow")
	}
	return mintPrice * amount
}
