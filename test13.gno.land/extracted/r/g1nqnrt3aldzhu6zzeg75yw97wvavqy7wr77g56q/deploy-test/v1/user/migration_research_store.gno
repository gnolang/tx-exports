package user

import (
	"strings"

	olduser "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/user"
)

type UserStore = olduser.UserStore

const (
	MigrationResearchExpectedMetadata       = `{"role":"researcher","tier":"gold"}`
	MigrationResearchExpectedIntroduction   = "migration"
	MigrationResearchExpectedAppearanceRate = "1"
)

var (
	userStore *UserStore
	listLimit int
)

func GetTotalUserSize() int {
	return userStore.Total()
}

func HasUser(addr address) bool {
	return userStore.Has(addr)
}

func GetNickname(addr address) string {
	return userStore.NicknameByAddress(addr)
}

func HasNickname(nickname string) bool {
	return userStore.HasNickname(nickname)
}

func GetAddressByNickname(nickname string) address {
	return userStore.AddressByNickname(nickname)
}

func ListUserMetadataByAddresses(addrs ...address) []string {
	return userStore.ListUserMetadataByAddresses(addrs...)
}

func ListUsersByAddresses(addrs ...address) []map[string]string {
	return userStore.ListUsersByAddresses(addrs...)
}

func AdminUpdateUser(cur realm, addr address, keys string, values string) {
	userStore.Update(addr, migrationResearchProperties(keys, values))
}

func SetUserMetadata(cur realm, addr address, metadata string) {
	userStore.SetMetadata(addr, metadata)
}

func AdminDeleteUser(cur realm, addr address) {
	userStore.Delete(addr)
}

func migrationResearchNickname(addr address) string {
	addrStr := addr.String()
	if len(addrStr) < 12 {
		return "mr_" + addrStr
	}
	return "mr_" + addrStr[2:12]
}

func migrationResearchProperties(keys string, values string) map[string]string {
	keyParts := strings.Split(keys, ",")
	valueParts := strings.Split(values, ",")
	if len(keyParts) != len(valueParts) {
		panic("properties length mismatch")
	}

	props := make(map[string]string)
	for i, key := range keyParts {
		props[key] = valueParts[i]
	}
	return props
}
