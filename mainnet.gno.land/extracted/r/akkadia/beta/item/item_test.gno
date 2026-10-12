package item

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/admin"
)

var itemTest = struct {
	Admin, Operator, Owner, Other address
	SetupDone                     bool
}{
	Admin:    testutils.TestAddress("itemAdmin"),
	Operator: testutils.TestAddress("itemOperator"),
	Owner:    testutils.TestAddress("itemOwner"),
	Other:    testutils.TestAddress("itemOther"),
}

func setupItemTest(cur realm, t *testing.T) {
	t.Helper()
	resetItemState()
	testing.SetOriginSend(chain.Coins{})
	if itemTest.SetupDone {
		return
	}
	originalAdmin := admin.GetAdmin()
	testing.SetOriginCaller(originalAdmin)
	testing.SetRealm(testing.NewUserRealm(originalAdmin))
	admin.TransferAdmin(cross(cur), itemTest.Admin)
	testing.SetOriginCaller(itemTest.Admin)
	testing.SetRealm(testing.NewUserRealm(itemTest.Admin))
	admin.AcceptAdmin(cross(cur))
	admin.SetOperator(cross(cur), itemTest.Operator)
	itemTest.SetupDone = true
}

func TestSafeMintTracksSupply(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	SafeMint(cross(cur), itemTest.Owner, "42", 5)
	uassert.Equal(t, int64(5), BalanceOf(itemTest.Owner, "42"))
	uassert.Equal(t, int64(5), TotalSupply("42"))
	SafeMint(cross(cur), itemTest.Owner, "42", 1)
	SafeMint(cross(cur), itemTest.Other, "42", 2)
	uassert.Equal(t, int64(6), BalanceOf(itemTest.Owner, "42"))
	uassert.Equal(t, int64(2), BalanceOf(itemTest.Other, "42"))
	uassert.Equal(t, int64(8), TotalSupply("42"))
}

func TestItemTokenIDAcceptsOpaqueStrings(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	SafeMint(cross(cur), itemTest.Owner, "0", 1)
	SafeMint(cross(cur), itemTest.Owner, "4294967295", 2)
	SafeMint(cross(cur), itemTest.Owner, "sword", 3)
	uassert.Equal(t, int64(1), BalanceOf(itemTest.Owner, "0"))
	uassert.Equal(t, int64(2), TotalSupply("4294967295"))
	uassert.Equal(t, int64(3), TotalSupply("sword"))
	uassert.AbortsWithMessage(t, cur, "token id is required", func() {
		SafeMint(cross(cur), itemTest.Owner, "", 1)
	})
}

func TestItemTransferAndBurnUpdateSupply(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	SafeMint(cross(cur), itemTest.Owner, "42", 5)
	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(testing.NewUserRealm(itemTest.Owner))
	SafeTransferFrom(cross(cur), itemTest.Owner, itemTest.Other, "42", 2)
	Burn(cross(cur), itemTest.Owner, "42", 1)
	uassert.Equal(t, int64(2), BalanceOf(itemTest.Owner, "42"))
	uassert.Equal(t, int64(2), BalanceOf(itemTest.Other, "42"))
	uassert.Equal(t, int64(4), TotalSupply("42"))
}

func TestItemApprovalAllowsTransferAndBurn(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	SafeMint(cross(cur), itemTest.Owner, "42", 5)
	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(testing.NewUserRealm(itemTest.Owner))
	SetApprovalForAll(cross(cur), itemTest.Other, true)
	testing.SetOriginCaller(itemTest.Other)
	testing.SetRealm(testing.NewUserRealm(itemTest.Other))
	SafeTransferFrom(cross(cur), itemTest.Owner, itemTest.Admin, "42", 2)
	Burn(cross(cur), itemTest.Owner, "42", 1)
	uassert.Equal(t, int64(2), BalanceOf(itemTest.Owner, "42"))
	uassert.Equal(t, int64(2), BalanceOf(itemTest.Admin, "42"))
	uassert.Equal(t, int64(4), TotalSupply("42"))
}

func TestSafeMintSecurity(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(testing.NewUserRealm(itemTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		SafeMint(cross(cur), itemTest.Owner, "1", 1)
	})
	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/item_relay"))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		SafeMint(cross(cur), itemTest.Owner, "1", 1)
	})
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	uassert.AbortsWithMessage(t, cur, "attached coins not allowed", func() {
		SafeMint(cross(cur), itemTest.Owner, "1", 1)
	})
}

func TestItemOwnedList(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	uassert.Equal(t, 0, GetOwnedCount(itemTest.Owner))
	uassert.Equal(t, 0, len(ListByOwner(itemTest.Owner, 1, 10)))
	uassert.PanicsWithMessage(t, cur, "invalid item owner", func() {
		GetOwnedCount(address(""))
	})
	uassert.PanicsWithMessage(t, cur, "page must be at least 1", func() {
		ListByOwner(itemTest.Owner, 0, 1)
	})
	uassert.PanicsWithMessage(t, cur, "count must be at least 1", func() {
		ListByOwner(itemTest.Owner, 1, 0)
	})
	uassert.PanicsWithMessage(t, cur, "count exceeds listLimit (max: 100)", func() {
		ListByOwner(itemTest.Owner, 1, 101)
	})
	uassert.Equal(t, 100, GetListLimit())

	SafeMint(cross(cur), itemTest.Owner, "10", 5)
	SafeMint(cross(cur), itemTest.Owner, "20", 3)
	SafeMint(cross(cur), itemTest.Owner, "30", 1)
	uassert.Equal(t, 3, GetOwnedCount(itemTest.Owner))
	page1 := ListByOwner(itemTest.Owner, 1, 2)
	uassert.Equal(t, 2, len(page1))
	uassert.Equal(t, "10", page1[0]["tokenId"])
	uassert.Equal(t, "5", page1[0]["amount"])
	uassert.Equal(t, "20", page1[1]["tokenId"])
	page2 := ListByOwner(itemTest.Owner, 2, 2)
	uassert.Equal(t, 1, len(page2))
	uassert.Equal(t, "30", page2[0]["tokenId"])
	uassert.Equal(t, 0, len(ListByOwner(itemTest.Owner, 3, 2)))
	page1[0]["amount"] = "hacked"
	uassert.Equal(t, "5", ListByOwner(itemTest.Owner, 1, 1)[0]["amount"])

	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(testing.NewUserRealm(itemTest.Owner))
	SafeTransferFrom(cross(cur), itemTest.Owner, itemTest.Other, "10", 2)
	uassert.Equal(t, 3, GetOwnedCount(itemTest.Owner))
	uassert.Equal(t, 1, GetOwnedCount(itemTest.Other))
	uassert.Equal(t, "3", ListByOwner(itemTest.Owner, 1, 10)[0]["amount"])
	uassert.Equal(t, "2", ListByOwner(itemTest.Other, 1, 10)[0]["amount"])
	SafeTransferFrom(cross(cur), itemTest.Owner, itemTest.Other, "10", 3)
	uassert.Equal(t, 2, GetOwnedCount(itemTest.Owner))
	uassert.Equal(t, 1, GetOwnedCount(itemTest.Other))
	Burn(cross(cur), itemTest.Owner, "20", 3)
	uassert.Equal(t, 1, GetOwnedCount(itemTest.Owner))
	uassert.Equal(t, "30", ListByOwner(itemTest.Owner, 1, 10)[0]["tokenId"])

	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	SafeMint(cross(cur), itemTest.Owner, "30", 2)
	uassert.Equal(t, 1, GetOwnedCount(itemTest.Owner))
	uassert.Equal(t, "3", ListByOwner(itemTest.Owner, 1, 10)[0]["amount"])
}

func TestSetListLimit(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)

	testing.SetOriginCaller(itemTest.Admin)
	testing.SetRealm(testing.NewUserRealm(itemTest.Admin))
	SetListLimit(cross(cur), 50)
	uassert.Equal(t, 50, GetListLimit())

	SetListLimit(cross(cur), 1)
	uassert.PanicsWithMessage(t, cur, "count exceeds listLimit (max: 1)", func() {
		ListByOwner(itemTest.Owner, 1, 2)
	})

	uassert.AbortsWithMessage(t, cur, "limit must be at least 1", func() {
		SetListLimit(cross(cur), 0)
	})
	uassert.AbortsWithMessage(t, cur, "limit must be at least 1", func() {
		SetListLimit(cross(cur), -1)
	})

	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})

	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(testing.NewUserRealm(itemTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})

	testing.SetOriginCaller(itemTest.Admin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/item_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})
}

func TestSetMinterRealm(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	minterPath := "gno.land/r/example/item_minter"
	minter := testing.NewCodeRealm(minterPath)
	minterAddr := minter.Address()

	uassert.Equal(t, minterAddr.String(), chain.PackageAddress(minterPath).String())
	uassert.Equal(t, false, IsMinterRealm(minterAddr))

	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetMinterRealm(cross(cur), minterPath)
	})

	testing.SetOriginCaller(itemTest.Admin)
	testing.SetRealm(testing.NewUserRealm(itemTest.Admin))
	uassert.AbortsWithMessage(t, cur, "package path is required", func() {
		SetMinterRealm(cross(cur), "")
	})
	uassert.AbortsWithMessage(t, cur, "invalid package path", func() {
		SetMinterRealm(cross(cur), "gno.land/p/akkadia/beta/item")
	})
	SetMinterRealm(cross(cur), minterPath)
	uassert.Equal(t, true, IsMinterRealm(minterAddr))
	SetMinterRealm(cross(cur), minterPath)
	uassert.Equal(t, true, IsMinterRealm(minterAddr))

	UnsetMinterRealm(cross(cur), minterPath)
	uassert.Equal(t, false, IsMinterRealm(minterAddr))
	uassert.AbortsWithMessage(t, cur, "package path is not a minter realm", func() {
		UnsetMinterRealm(cross(cur), minterPath)
	})
	uassert.AbortsWithMessage(t, cur, "package path is required", func() {
		UnsetMinterRealm(cross(cur), "")
	})

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/item_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetMinterRealm(cross(cur), minterPath)
	})
}

func TestSafeMintFromRealm(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	minter := testing.NewCodeRealm("gno.land/r/example/item_minter")
	unregistered := testing.NewCodeRealm("gno.land/r/example/item_minter_other")

	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(testing.NewUserRealm(itemTest.Owner))
	uassert.AbortsWithMessage(t, cur, "user calls not allowed: function must be called by a realm", func() {
		SafeMintFromRealm(cross(cur), itemTest.Owner, "1", 1)
	})

	testing.SetRealm(unregistered)
	uassert.AbortsWithMessage(t, cur, "minter realm required", func() {
		SafeMintFromRealm(cross(cur), itemTest.Owner, "1", 1)
	})

	testing.SetOriginCaller(itemTest.Admin)
	testing.SetRealm(testing.NewUserRealm(itemTest.Admin))
	SetMinterRealm(cross(cur), "gno.land/r/example/item_minter")

	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(minter)
	SafeMintFromRealm(cross(cur), itemTest.Owner, "7", 3)
	uassert.Equal(t, int64(3), BalanceOf(itemTest.Owner, "7"))
	uassert.Equal(t, int64(3), TotalSupply("7"))
	uassert.Equal(t, 1, GetOwnedCount(itemTest.Owner))

	uassert.AbortsWithMessage(t, cur, "item recipient must be origin caller", func() {
		SafeMintFromRealm(cross(cur), itemTest.Other, "8", 1)
	})
	uassert.Equal(t, int64(0), TotalSupply("8"))

	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	SafeMintFromRealm(cross(cur), itemTest.Owner, "9", 1)
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, int64(1), BalanceOf(itemTest.Owner, "9"))
}

func TestBurnFromRealm(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	minter := testing.NewCodeRealm("gno.land/r/example/item_minter")

	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	SafeMint(cross(cur), itemTest.Owner, "42", 5)

	testing.SetOriginCaller(itemTest.Admin)
	testing.SetRealm(testing.NewUserRealm(itemTest.Admin))
	SetMinterRealm(cross(cur), "gno.land/r/example/item_minter")

	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(testing.NewUserRealm(itemTest.Owner))
	uassert.AbortsWithMessage(t, cur, "user calls not allowed: function must be called by a realm", func() {
		BurnFromRealm(cross(cur), itemTest.Owner, "42", 1)
	})

	testing.SetRealm(minter)
	uassert.AbortsWithMessage(t, cur, "item owner must be origin caller", func() {
		BurnFromRealm(cross(cur), itemTest.Other, "42", 1)
	})
	uassert.Equal(t, int64(5), BalanceOf(itemTest.Owner, "42"))

	BurnFromRealm(cross(cur), itemTest.Owner, "42", 2)
	uassert.Equal(t, int64(3), BalanceOf(itemTest.Owner, "42"))
	uassert.Equal(t, int64(3), TotalSupply("42"))

	uassert.AbortsWithMessage(t, cur, "item amount must be positive", func() {
		SafeMintFromRealm(cross(cur), itemTest.Owner, "99", 0)
	})
	uassert.Equal(t, int64(3), BalanceOf(itemTest.Owner, "42"))
	uassert.Equal(t, int64(3), TotalSupply("42"))
	uassert.Equal(t, int64(0), TotalSupply("99"))
	uassert.Equal(t, 1, GetOwnedCount(itemTest.Owner))

	testing.SetOriginCaller(itemTest.Admin)
	testing.SetRealm(testing.NewUserRealm(itemTest.Admin))
	UnsetMinterRealm(cross(cur), "gno.land/r/example/item_minter")
	testing.SetOriginCaller(itemTest.Owner)
	testing.SetRealm(minter)
	uassert.AbortsWithMessage(t, cur, "minter realm required", func() {
		BurnFromRealm(cross(cur), itemTest.Owner, "42", 1)
	})
	uassert.Equal(t, int64(3), BalanceOf(itemTest.Owner, "42"))
}
