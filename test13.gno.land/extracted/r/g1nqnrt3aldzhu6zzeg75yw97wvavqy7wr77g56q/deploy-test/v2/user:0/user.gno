package user

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
)

// Events
const (
	CreateUserEvent      = "CreateUser"
	UpdateUserEvent      = "UpdateUser"
	DeleteUserEvent      = "DeleteUser"
	SetUserMetadataEvent = "SetMetadata"
)

func HasUser(addr address) bool {
	assertMigrationStateAvailable()
	assertIsValidAddress(addr)
	return userStore.Has(addr)
}

func CreateUser(cur realm, propKeys, propValues string) {
	assertNotFrozen()
	addr := accesscontrol.MustGetUserCaller(0, cur)
	assertIsValidAddress(addr)
	props := parsePropertiesCSV(propKeys, propValues)
	validateCreateProperties(props)
	userStore.Create(addr, props)
	addrStr := addr.String()
	chain.Emit(CreateUserEvent,
		"address", addrStr,
	)
}

func UpdateUser(cur realm, propKeys, propValues string) {
	assertNotFrozen()
	addr := accesscontrol.MustGetUserCaller(0, cur)
	assertIsValidAddress(addr)
	props := parsePropertiesCSV(propKeys, propValues)
	validateUpdateProperties(props)
	userStore.Update(addr, props)
	addrStr := addr.String()
	chain.Emit(UpdateUserEvent,
		"address", addrStr,
	)
}

func DeleteUser(cur realm) {
	assertNotFrozen()
	addr := accesscontrol.MustGetUserCaller(0, cur)
	assertIsValidAddress(addr)
	userStore.Delete(addr)
	addrStr := addr.String()
	chain.Emit(DeleteUserEvent,
		"address", addrStr,
	)
}

func GetNickname(addr address) string {
	assertMigrationStateAvailable()
	assertIsValidAddress(addr)
	return userStore.NicknameByAddress(addr)
}

func GetAddressByNickname(nickname string) address {
	assertMigrationStateAvailable()
	assertValidNickname(nickname)
	return userStore.AddressByNickname(nickname)
}

func HasNickname(nickname string) bool {
	assertMigrationStateAvailable()
	assertValidNickname(nickname)
	return userStore.HasNickname(nickname)
}

func ListUsersByAddresses(addrs ...address) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("addrs", len(addrs))
	assertValidAddresses(addrs)

	return userStore.ListUsersByAddresses(addrs...)
}

func ListUserMetadataByAddresses(addrs ...address) []string {
	assertMigrationStateAvailable()
	assertListLimit("addrs", len(addrs))
	assertValidAddresses(addrs)

	return userStore.ListUserMetadataByAddresses(addrs...)
}

func GetTotalUserSize() int {
	assertMigrationStateAvailable()
	return userStore.Total()
}

func ListUsers(page, count int) []string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)

	return userStore.List(page, count)
}
