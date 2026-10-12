package user

import (
	"testing"
	"time"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/admin"
)

var (
	testAdmin   = testutils.TestAddress("testAdmin")
	regularUser = testutils.TestAddress("regularUser")
	badUser     = testutils.TestAddress("badUser")
	anotherUser = testutils.TestAddress("anotherUser")
	setupDone   = false
)

func setupUserTests(cur realm, t *testing.T) {
	t.Helper()
	users = bptree.BPTree{}
	listLimit = 100
	isFrozen = true

	if setupDone {
		return
	}
	originalAdmin := admin.GetAdmin()
	testing.SetOriginCaller(originalAdmin)
	testing.SetRealm(testing.NewUserRealm(originalAdmin))
	admin.TransferAdmin(cross(cur), testAdmin)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.AcceptAdmin(cross(cur))
	setupDone = true
}

func createUserForTest(cur realm, addr address) {
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AdminCreateUser(cross(cur), addr)
}

func TestParsePropertiesCSV(cur realm, t *testing.T) {
	props := parsePropertiesCSV("nickname,introduction", "Alice,hello%2C%20world")
	uassert.Equal(t, "Alice", props["nickname"])
	uassert.Equal(t, "hello, world", props["introduction"])

	props = parsePropertiesCSV("nickname,introduction", "Alice,")
	uassert.Equal(t, "", props["introduction"])

	uassert.PanicsWithMessage(t, cur, "properties keys must be not empty", func() {
		parsePropertiesCSV("", "")
	})
	uassert.PanicsWithMessage(t, cur, "properties key duplicated: nickname", func() {
		parsePropertiesCSV("nickname,nickname", "Alice,Bob")
	})
	uassert.PanicsWithMessage(t, cur, "properties keys and values count mismatch", func() {
		parsePropertiesCSV("nickname,introduction", "Alice")
	})
	uassert.PanicsWithMessage(t, cur, "properties value URL decode failed: introduction", func() {
		parsePropertiesCSV("nickname,introduction", "Alice,%zz")
	})
}

func TestCreateUser(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetFrozen(cross(cur), false)
	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewUserRealm(regularUser))
	CreateUser(cross(cur))
	uassert.True(t, HasUser(regularUser))
	uassert.False(t, HasUser(testAdmin))
	uassert.Equal(t, 1, GetTotalUserSize())
	createdAt := ListUsersByAddresses(regularUser)[0][createdAtKey]
	uassert.True(t, createdAt != "")
	uassert.AbortsWithMessage(t, cur, "user already exists: "+regularUser.String(), func() {
		CreateUser(cross(cur))
	})
	uassert.Equal(t, createdAt, ListUsersByAddresses(regularUser)[0][createdAtKey])
	// Operator delivery after self-registration remains a safe no-op.
	createUserForTest(cross(cur), regularUser)
	uassert.Equal(t, 1, GetTotalUserSize())
	uassert.Equal(t, createdAt, ListUsersByAddresses(regularUser)[0][createdAtKey])
}

func TestCreateUserRejectsCodeRealm(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetFrozen(cross(cur), false)
	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/user_relay"))
	uassert.AbortsWithMessage(t, cur, "contract calls not allowed: function must be called directly by user", func() {
		CreateUser(cross(cur))
	})
	uassert.Equal(t, 0, GetTotalUserSize())
}

func TestAdminCreateUser(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)

	createUserForTest(cross(cur), regularUser)
	uassert.True(t, HasUser(regularUser))
	uassert.Equal(t, 1, GetTotalUserSize())
	usersByAddr := ListUsersByAddresses(regularUser)
	uassert.Equal(t, 1, len(usersByAddr))
	uassert.Equal(t, regularUser.String(), usersByAddr[0]["address"])
	uassert.True(t, usersByAddr[0][createdAtKey] != "")

	createdAt := usersByAddr[0][createdAtKey]
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(time.Hour)
	testing.SetContext(ctx)
	createUserForTest(cross(cur), regularUser)
	uassert.Equal(t, 1, GetTotalUserSize())
	uassert.Equal(t, createdAt, ListUsersByAddresses(regularUser)[0][createdAtKey])
}

func TestAdminCreateUserOperator(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.SetOperator(cross(cur), anotherUser)
	testing.SetOriginCaller(anotherUser)
	testing.SetRealm(testing.NewUserRealm(anotherUser))
	AdminCreateUser(cross(cur), regularUser)
	uassert.True(t, HasUser(regularUser))
	uassert.False(t, HasUser(anotherUser))
	uassert.Equal(t, 1, GetTotalUserSize())
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.UnsetOperator(cross(cur), anotherUser)
}

func TestAdminCreateUserRejectsUnauthorizedAndInvalidAddress(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	createUserForTest(cross(cur), regularUser)
	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewUserRealm(regularUser))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		AdminCreateUser(cross(cur), anotherUser)
	})
	// Authorization must run even when the target already exists.
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		AdminCreateUser(cross(cur), regularUser)
	})
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/user_relay"))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		AdminCreateUser(cross(cur), anotherUser)
	})
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	uassert.AbortsWithMessage(t, cur, "invalid address: "+address("").String(), func() {
		AdminCreateUser(cross(cur), address(""))
	})
	uassert.True(t, HasUser(regularUser))
	uassert.False(t, HasUser(anotherUser))
	uassert.Equal(t, 1, GetTotalUserSize())
}

func TestDeleteUser(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetFrozen(cross(cur), false)
	createUserForTest(cross(cur), regularUser)

	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewUserRealm(regularUser))
	DeleteUser(cross(cur))
	uassert.False(t, HasUser(regularUser))
	uassert.Equal(t, 0, GetTotalUserSize())

	uassert.AbortsWithMessage(t, cur, "user not found: "+regularUser.String(), func() {
		DeleteUser(cross(cur))
	})
}

func TestAdminDeleteUser(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	createUserForTest(cross(cur), regularUser)

	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewUserRealm(regularUser))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		AdminDeleteUser(cross(cur), regularUser)
	})

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AdminDeleteUser(cross(cur), regularUser)
	uassert.False(t, HasUser(regularUser))

	uassert.AbortsWithMessage(t, cur, "user not found: "+regularUser.String(), func() {
		AdminDeleteUser(cross(cur), regularUser)
	})
}

func TestAdminUpdateUser(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	createUserForTest(cross(cur), regularUser)
	createdAt := ListUsersByAddresses(regularUser)[0][createdAtKey]

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AdminUpdateUser(cross(cur), regularUser, "nickname,introduction", "Alice,hello%2C%20world")
	listed := ListUsersByAddresses(regularUser)[0]
	uassert.Equal(t, "Alice", listed["nickname"])
	uassert.Equal(t, "hello, world", listed["introduction"])
	uassert.Equal(t, createdAt, listed[createdAtKey])

	AdminUpdateUser(cross(cur), regularUser, createdAtKey, "1")
	uassert.Equal(t, "1", ListUsersByAddresses(regularUser)[0][createdAtKey])
	uassert.Equal(t, "Alice", ListUsersByAddresses(regularUser)[0]["nickname"])
}

func TestAdminUpdateUserRejectsMissingAndUnauthorized(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	uassert.AbortsWithMessage(t, cur, "user not found: "+regularUser.String(), func() {
		AdminUpdateUser(cross(cur), regularUser, "nickname", "Alice")
	})

	createUserForTest(cross(cur), regularUser)
	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewUserRealm(regularUser))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		AdminUpdateUser(cross(cur), regularUser, "nickname", "Alice")
	})

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/user_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		AdminUpdateUser(cross(cur), regularUser, "nickname", "Alice")
	})
}

func TestListUsersAddressOrder(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	createUserForTest(cross(cur), regularUser)
	createUserForTest(cross(cur), anotherUser)

	listed := ListUsers(1, 10)
	uassert.Equal(t, 2, len(listed))
	if regularUser.String() < anotherUser.String() {
		uassert.Equal(t, regularUser.String(), listed[0])
		uassert.Equal(t, anotherUser.String(), listed[1])
	} else {
		uassert.Equal(t, anotherUser.String(), listed[0])
		uassert.Equal(t, regularUser.String(), listed[1])
	}

	firstPage := ListUsers(1, 1)
	uassert.Equal(t, 1, len(firstPage))
	uassert.Equal(t, listed[0], firstPage[0])
	secondPage := ListUsers(2, 1)
	uassert.Equal(t, listed[1], secondPage[0])
}

func TestListUsersByAddresses(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	createUserForTest(cross(cur), regularUser)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AdminUpdateUser(cross(cur), regularUser, "nickname", "Alice")

	listed := ListUsersByAddresses(regularUser, badUser)
	uassert.Equal(t, 1, len(listed))
	uassert.Equal(t, "Alice", listed[0]["nickname"])
	listed[0]["nickname"] = "mutated"
	again := ListUsersByAddresses(regularUser)
	uassert.Equal(t, "Alice", again[0]["nickname"])
}

func TestListInputValidation(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	uassert.PanicsWithMessage(t, cur, "page must be at least 1", func() {
		ListUsers(0, 1)
	})
	uassert.PanicsWithMessage(t, cur, "count must be at least 1", func() {
		ListUsers(1, 0)
	})
	uassert.PanicsWithMessage(t, cur, "count exceeds listLimit (max: 100)", func() {
		ListUsers(1, 101)
	})
	uassert.PanicsWithMessage(t, cur, "invalid address: "+address("").String(), func() {
		HasUser(address(""))
	})
	uassert.Equal(t, 100, GetListLimit())
}

func TestSetListLimit(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetListLimit(cross(cur), 50)
	uassert.Equal(t, 50, GetListLimit())

	SetListLimit(cross(cur), 1)
	uassert.PanicsWithMessage(t, cur, "addrs exceeds listLimit (max: 1)", func() {
		ListUsersByAddresses(regularUser, badUser)
	})
	uassert.PanicsWithMessage(t, cur, "count exceeds listLimit (max: 1)", func() {
		ListUsers(1, 2)
	})

	uassert.AbortsWithMessage(t, cur, "limit must be at least 1", func() {
		SetListLimit(cross(cur), 0)
	})
	uassert.AbortsWithMessage(t, cur, "limit must be at least 1", func() {
		SetListLimit(cross(cur), -1)
	})

	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewUserRealm(regularUser))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/user_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})
}

func TestSelfServiceFrozen(cur realm, t *testing.T) {
	uassert.True(t, isFrozen)
	setupUserTests(cross(cur), t)
	createUserForTest(cross(cur), regularUser)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AdminUpdateUser(cross(cur), regularUser, "nickname", "Alice")
	before := ListUsersByAddresses(regularUser)

	testing.SetOriginCaller(anotherUser)
	testing.SetRealm(testing.NewUserRealm(anotherUser))
	uassert.AbortsWithMessage(t, cur, "user self-service is frozen", func() {
		CreateUser(cross(cur))
	})
	uassert.False(t, HasUser(anotherUser))
	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewUserRealm(regularUser))
	uassert.AbortsWithMessage(t, cur, "user self-service is frozen", func() {
		DeleteUser(cross(cur))
	})
	uassert.Equal(t, before[0][createdAtKey], ListUsersByAddresses(regularUser)[0][createdAtKey])
	uassert.Equal(t, "Alice", ListUsersByAddresses(regularUser)[0]["nickname"])
	uassert.Equal(t, 1, GetTotalUserSize())

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetFrozen(cross(cur), false)
	testing.SetOriginCaller(anotherUser)
	testing.SetRealm(testing.NewUserRealm(anotherUser))
	CreateUser(cross(cur))
	uassert.True(t, HasUser(anotherUser))
	DeleteUser(cross(cur))
	uassert.False(t, HasUser(anotherUser))

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetFrozen(cross(cur), true)
	testing.SetOriginCaller(anotherUser)
	testing.SetRealm(testing.NewUserRealm(anotherUser))
	uassert.AbortsWithMessage(t, cur, "user self-service is frozen", func() {
		CreateUser(cross(cur))
	})
	testing.SetOriginCaller(regularUser)
	testing.SetRealm(testing.NewUserRealm(regularUser))
	uassert.AbortsWithMessage(t, cur, "user self-service is frozen", func() {
		DeleteUser(cross(cur))
	})
	uassert.Equal(t, before[0][createdAtKey], ListUsersByAddresses(regularUser)[0][createdAtKey])
	uassert.Equal(t, "Alice", ListUsersByAddresses(regularUser)[0]["nickname"])
	uassert.Equal(t, 1, GetTotalUserSize())
}

func TestSetFrozenRejectsUnauthorized(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.SetOperator(cross(cur), anotherUser)

	for _, frozen := range []bool{true, false} {
		testing.SetOriginCaller(testAdmin)
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		SetFrozen(cross(cur), frozen)
		for _, caller := range []address{regularUser, anotherUser} {
			testing.SetOriginCaller(caller)
			testing.SetRealm(testing.NewUserRealm(caller))
			uassert.AbortsWithMessage(t, cur, "admin access required", func() {
				SetFrozen(cross(cur), !frozen)
			})
			uassert.Equal(t, frozen, isFrozen)
		}
		testing.SetOriginCaller(testAdmin)
		testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/user_admin_relay"))
		uassert.AbortsWithMessage(t, cur, "admin access required", func() {
			SetFrozen(cross(cur), !frozen)
		})
		uassert.Equal(t, frozen, isFrozen)
	}
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.UnsetOperator(cross(cur), anotherUser)
	SetFrozen(cross(cur), true)
}

func TestDeleteAll(cur realm, t *testing.T) {
	for _, frozen := range []bool{true, false} {
		setupUserTests(cross(cur), t)
		createUserForTest(cross(cur), regularUser)
		createUserForTest(cross(cur), anotherUser)
		testing.SetOriginCaller(testAdmin)
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		AdminUpdateUser(cross(cur), regularUser, "nickname", "Alice")
		SetListLimit(cross(cur), 7)
		SetFrozen(cross(cur), frozen)

		DeleteAll(cross(cur))
		uassert.Equal(t, 0, GetTotalUserSize())
		uassert.False(t, HasUser(regularUser))
		uassert.False(t, HasUser(anotherUser))
		uassert.Equal(t, 0, len(ListUsers(1, 7)))
		uassert.Equal(t, 0, len(ListUsersByAddresses(regularUser, anotherUser)))
		uassert.Equal(t, 7, GetListLimit())
		uassert.Equal(t, frozen, isFrozen)
		// Empty resets are safe, and re-registration must not restore old properties.
		DeleteAll(cross(cur))
		AdminCreateUser(cross(cur), regularUser)
		uassert.Equal(t, 1, GetTotalUserSize())
		uassert.True(t, HasUser(regularUser))
		props := ListUsersByAddresses(regularUser)[0]
		uassert.Equal(t, "", props["nickname"])
		uassert.True(t, props[createdAtKey] != "")
	}
}

func TestDeleteAllAuthority(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	createUserForTest(cross(cur), regularUser)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AdminUpdateUser(cross(cur), regularUser, "nickname", "Alice")
	admin.SetOperator(cross(cur), anotherUser)
	for _, caller := range []address{regularUser, anotherUser} {
		testing.SetOriginCaller(caller)
		testing.SetRealm(testing.NewUserRealm(caller))
		uassert.AbortsWithMessage(t, cur, "admin access required", func() {
			DeleteAll(cross(cur))
		})
		uassert.Equal(t, 1, GetTotalUserSize())
		uassert.Equal(t, "Alice", ListUsersByAddresses(regularUser)[0]["nickname"])
	}
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/user_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		DeleteAll(cross(cur))
	})
	uassert.Equal(t, 1, GetTotalUserSize())
	uassert.Equal(t, "Alice", ListUsersByAddresses(regularUser)[0]["nickname"])
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.UnsetOperator(cross(cur), anotherUser)
}
