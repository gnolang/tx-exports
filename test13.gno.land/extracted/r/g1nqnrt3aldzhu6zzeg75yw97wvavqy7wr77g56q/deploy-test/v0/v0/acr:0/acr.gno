package acr

import (
	"chain"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const (
	MintEvent = "Mint"
)

var acrStore *ACRStore

func init(cur realm) {
	acrStore = newACRStore(cur)
}

// ==================== GRC-20 Standard ====================

func GetName() string {
	assertMigrationStateAvailable()
	return acrStore.GetName()
}

func GetSymbol() string {
	assertMigrationStateAvailable()
	return acrStore.GetSymbol()
}

func GetDecimals() int {
	assertMigrationStateAvailable()
	return acrStore.GetDecimals()
}

func TotalSupply() int64 {
	assertMigrationStateAvailable()
	return acrStore.TotalSupply()
}

func BalanceOf(account address) int64 {
	assertMigrationStateAvailable()
	return acrStore.BalanceOf(account)
}

func Transfer(cur realm, to address, amount int64) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	acrStore.Transfer(caller, to, amount)
}

func Allowance(owner, spender address) int64 {
	assertMigrationStateAvailable()
	return acrStore.Allowance(owner, spender)
}

func Approve(cur realm, spender address, amount int64) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	acrStore.Approve(caller, spender, amount)
}

func TransferFrom(cur realm, from, to address, amount int64) {
	assertNotFrozen()
	spender := accesscontrol.MustGetUserCaller(0, cur)
	acrStore.TransferFrom(from, spender, to, amount)
}

// ==================== Admin Functions ====================

// Mint mints ACR tokens to a user
func Mint(cur realm, requestID string, to address, amount int64) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)
	acrStore.Mint(requestID, to, amount)

	chain.Emit(
		MintEvent,
		"requestID", requestID,
		"to", to.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
}

// IsRequestProcessed checks if a requestID has been processed
func IsRequestProcessed(requestID string) bool {
	assertMigrationStateAvailable()
	return acrStore.IsRequestProcessed(requestID)
}

// ListRequestProcessed checks multiple requestIDs and returns their processed status
func ListRequestProcessed(requestIDs ...string) map[string]bool {
	assertMigrationStateAvailable()
	if len(requestIDs) > listLimit {
		panic("requestIDs exceeds listLimit")
	}
	return acrStore.ListRequestProcessed(requestIDs...)
}

// Burn burns ACR tokens from caller
func Burn(cur realm, amount int64) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	acrStore.Burn(caller, amount)
}

// ListTopUsersByBalance returns top users sorted by balance (descending) with pagination
func ListTopUsersByBalance(count int) []map[string]string {
	assertMigrationStateAvailable()
	if count < 1 {
		panic("count must be at least 1")
	}
	if count > listLimit {
		panic("count exceeds listLimit")
	}
	return acrStore.ListTopUsersByBalance(count)
}

func MintedOf(account address) int64 {
	assertMigrationStateAvailable()
	return acrStore.MintedOf(account)
}

// ListTopUsersByMinting returns top users sorted by total minted amount (descending) with pagination
func ListTopUsersByMinting(count int) []map[string]string {
	assertMigrationStateAvailable()
	if count < 1 {
		panic("count must be at least 1")
	}
	if count > listLimit {
		panic("count exceeds listLimit")
	}
	return acrStore.ListTopUsersByMinting(count)
}
