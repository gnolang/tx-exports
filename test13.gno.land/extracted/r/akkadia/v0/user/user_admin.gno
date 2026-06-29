package user

import (
	"chain"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/validate"
	"gno.land/r/akkadia/v0/admin"
)

func AdminCreateUser(cur realm, addr address, propKeys, propValues string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertIsValidAddress(addr)
	props := parsePropertiesCSV(propKeys, propValues)
	validateCreateProperties(props)
	userStore.Create(addr, props)
	chain.Emit(CreateUserEvent,
		"address", addr.String(),
	)
}

func AdminUpdateUser(cur realm, addr address, propKeys, propValues string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertIsValidAddress(addr)
	props := parsePropertiesCSV(propKeys, propValues)
	validateUpdateProperties(props)
	userStore.Update(addr, props)
	chain.Emit(UpdateUserEvent,
		"address", addr.String(),
	)
}

func AdminDeleteUser(cur realm, addr address) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertIsValidAddress(addr)
	userStore.Delete(addr)
	chain.Emit(DeleteUserEvent,
		"address", addr.String(),
	)
}

func SetUserMetadata(cur realm, addr address, metadata string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)
	assertIsValidAddress(addr)
	validate.AssertStringTextLen(metadata, true, "user metadata")
	userStore.SetMetadata(addr, metadata)

	chain.Emit(
		SetUserMetadataEvent,
		"address", addr.String(),
	)
}
