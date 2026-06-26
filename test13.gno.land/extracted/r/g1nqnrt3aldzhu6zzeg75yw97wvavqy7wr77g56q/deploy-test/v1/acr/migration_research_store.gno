package acr

import oldacr "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/acr"

type ACRStore = oldacr.ACRStore

var (
	acrStore  *ACRStore
	frozen    bool
	listLimit int
)

func TotalSupply() int64 {
	return acrStore.TotalSupply()
}

func BalanceOf(owner address) int64 {
	return acrStore.BalanceOf(owner)
}

func MintedOf(owner address) int64 {
	return acrStore.MintedOf(owner)
}

func IsRequestProcessed(requestID string) bool {
	return acrStore.IsRequestProcessed(requestID)
}

func ListTopUsersByBalance(count int) []map[string]string {
	return acrStore.ListTopUsersByBalance(count)
}

func ListTopUsersByMinting(count int) []map[string]string {
	return acrStore.ListTopUsersByMinting(count)
}

func ListHofCategories() []string {
	return acrStore.ListHofCategories()
}

func GetHofEntries(category string) string {
	return acrStore.GetHofEntries(category)
}

func IsFrozen() bool {
	return frozen
}

func Freeze(cur realm) {
	frozen = true
}

func Unfreeze(cur realm) {
	frozen = false
}

func Mint(cur realm, requestID string, to address, amount int64) {
	acrStore.Mint(requestID, to, amount)
}
