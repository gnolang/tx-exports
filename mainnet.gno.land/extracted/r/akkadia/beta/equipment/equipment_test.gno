package equipment

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/admin"
)

var equipmentTest = struct {
	Admin, Operator, Owner, Other address
	SetupDone                     bool
}{
	Admin:    testutils.TestAddress("equipmentAdmin"),
	Operator: testutils.TestAddress("equipmentOperator"),
	Owner:    testutils.TestAddress("equipmentOwner"),
	Other:    testutils.TestAddress("equipmentOther"),
}

func setupEquipmentTest(cur realm, t *testing.T) {
	t.Helper()
	resetEquipmentState()
	testing.SetOriginSend(chain.Coins{})
	if equipmentTest.SetupDone {
		return
	}
	originalAdmin := admin.GetAdmin()
	testing.SetOriginCaller(originalAdmin)
	testing.SetRealm(testing.NewUserRealm(originalAdmin))
	admin.TransferAdmin(cross(cur), equipmentTest.Admin)
	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Admin))
	admin.AcceptAdmin(cross(cur))
	admin.SetOperator(cross(cur), equipmentTest.Operator)
	equipmentTest.SetupDone = true
}

func TestMintAllocatesSequentialTokenIDs(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	uassert.Equal(t, uint64(0), GetLatestTokenID())
	first := Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	second := Mint(cross(cur), equipmentTest.Other, 0, "", "")
	uassert.Equal(t, uint64(1), first)
	uassert.Equal(t, uint64(2), second)
	uassert.Equal(t, uint64(2), GetLatestTokenID())
	uassert.Equal(t, equipmentTest.Owner, OwnerOf(1))
	uassert.Equal(t, equipmentTest.Other, OwnerOf(2))
	uassert.True(t, Has(1))
	uassert.True(t, Has(2))
	uassert.False(t, Has(3))

	latestTokenID = maxEquipmentTokenID
	uassert.AbortsWithMessage(t, cur, "equipment token id exhausted", func() {
		Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	})
}

func TestEquipmentTransferAndBurn(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	TransferFrom(cross(cur), equipmentTest.Owner, equipmentTest.Other, 1)
	testing.SetOriginCaller(equipmentTest.Other)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Other))
	Burn(cross(cur), 1)
	uassert.PanicsWithMessage(t, cur, "equipment metadata not found: 1", func() {
		GetMetadata(1)
	})
	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 1101000, "enhancement", "3")
	uassert.Equal(t, uint64(2), GetLatestTokenID())
	uassert.Equal(t, equipmentTest.Owner, OwnerOf(2))
	meta := GetMetadata(2)
	uassert.Equal(t, "1101000", meta["definitionId"])
	uassert.Equal(t, "3", meta["enhancement"])
	uassert.True(t, meta[createdAtKey] != "")
}

func TestEquipmentApprovalAllowsTransferAndBurn(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	Approve(cross(cur), equipmentTest.Other, 1)
	SetApprovalForAll(cross(cur), equipmentTest.Other, true)
	testing.SetOriginCaller(equipmentTest.Other)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Other))
	TransferFrom(cross(cur), equipmentTest.Owner, equipmentTest.Admin, 1)
	Burn(cross(cur), 2)
	uassert.Equal(t, equipmentTest.Admin, OwnerOf(1))
	uassert.Equal(t, int64(0), BalanceOf(equipmentTest.Owner))
}

func TestMintSecurity(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	})
	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/equipment_relay"))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	})
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	uassert.AbortsWithMessage(t, cur, "attached coins not allowed", func() {
		Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	})
}

func TestEquipmentMetadata(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 1101000, "enhancement,note", "3,a%2Cb")
	meta := GetMetadata(1)
	uassert.Equal(t, "1101000", meta["definitionId"])
	uassert.Equal(t, "3", meta["enhancement"])
	uassert.Equal(t, "a,b", meta["note"])
	uassert.True(t, meta[createdAtKey] != "")
	uassert.Equal(t, 4, len(meta))
	meta["definitionId"] = "hacked"
	uassert.Equal(t, "1101000", GetMetadata(1)["definitionId"])

	cases := []struct {
		keys, values, panicMsg string
	}{
		{"definitionId", "1", "reserved key: definitionId"},
		{"tokenId", "1", "reserved key: tokenId"},
		{"created_at", "1", "reserved key: created_at"},
		{"a,a", "1,2", "attributes key duplicated: a"},
		{"a,b", "1", "attributes keys and values count mismatch"},
		{",a", "1,2", "attributes key must be not empty"},
	}
	for _, tc := range cases {
		keys, values, panicMsg := tc.keys, tc.values, tc.panicMsg
		uassert.AbortsWithMessage(t, cur, panicMsg, func() {
			Mint(cross(cur), equipmentTest.Owner, 1, keys, values)
		})
	}
	uassert.Equal(t, int64(1), BalanceOf(equipmentTest.Owner))
	uassert.PanicsWithMessage(t, cur, "equipment metadata not found: 2", func() {
		GetMetadata(2)
	})
}

func TestEquipmentOwnedList(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	uassert.Equal(t, 0, GetOwnedCount(equipmentTest.Owner))
	uassert.Equal(t, 0, len(ListByOwner(equipmentTest.Owner, 1, 10)))
	uassert.PanicsWithMessage(t, cur, "invalid equipment owner", func() {
		GetOwnedCount(address(""))
	})
	uassert.PanicsWithMessage(t, cur, "page must be at least 1", func() {
		ListByOwner(equipmentTest.Owner, 0, 1)
	})
	uassert.PanicsWithMessage(t, cur, "count must be at least 1", func() {
		ListByOwner(equipmentTest.Owner, 1, 0)
	})
	uassert.PanicsWithMessage(t, cur, "count exceeds listLimit (max: 100)", func() {
		ListByOwner(equipmentTest.Owner, 1, 101)
	})
	uassert.Equal(t, 100, GetListLimit())

	Mint(cross(cur), equipmentTest.Owner, 1101000, "enhancement", "3")
	Mint(cross(cur), equipmentTest.Owner, 1101001, "", "")
	Mint(cross(cur), equipmentTest.Owner, 1101002, "", "")
	uassert.Equal(t, 3, GetOwnedCount(equipmentTest.Owner))
	uassert.Equal(t, int64(3), BalanceOf(equipmentTest.Owner))
	page1 := ListByOwner(equipmentTest.Owner, 1, 2)
	uassert.Equal(t, 2, len(page1))
	uassert.Equal(t, "1", page1[0]["tokenId"])
	uassert.Equal(t, "1101000", page1[0]["definitionId"])
	uassert.Equal(t, "3", page1[0]["enhancement"])
	uassert.Equal(t, "2", page1[1]["tokenId"])
	page2 := ListByOwner(equipmentTest.Owner, 2, 2)
	uassert.Equal(t, 1, len(page2))
	uassert.Equal(t, "3", page2[0]["tokenId"])
	uassert.Equal(t, 0, len(ListByOwner(equipmentTest.Owner, 3, 2)))
	page1[0]["definitionId"] = "hacked"
	uassert.Equal(t, "1101000", ListByOwner(equipmentTest.Owner, 1, 1)[0]["definitionId"])

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	TransferFrom(cross(cur), equipmentTest.Owner, equipmentTest.Other, 1)
	uassert.Equal(t, 2, GetOwnedCount(equipmentTest.Owner))
	uassert.Equal(t, 1, GetOwnedCount(equipmentTest.Other))
	uassert.Equal(t, "1", ListByOwner(equipmentTest.Other, 1, 10)[0]["tokenId"])
	testing.SetOriginCaller(equipmentTest.Other)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Other))
	Burn(cross(cur), 1)
	uassert.Equal(t, 0, GetOwnedCount(equipmentTest.Other))
	uassert.Equal(t, 2, GetOwnedCount(equipmentTest.Owner))

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Admin, 1101999, "enhancement", "9")
	uassert.Equal(t, uint64(4), GetLatestTokenID())
	uassert.Equal(t, 1, GetOwnedCount(equipmentTest.Admin))
	uassert.Equal(t, "4", ListByOwner(equipmentTest.Admin, 1, 1)[0]["tokenId"])
	uassert.Equal(t, "1101999", ListByOwner(equipmentTest.Admin, 1, 1)[0]["definitionId"])
	Mint(cross(cur), equipmentTest.Other, 1, "", "")
	uassert.Equal(t, uint64(5), GetLatestTokenID())
	uassert.Equal(t, 1, GetOwnedCount(equipmentTest.Other))
}

func TestSetListLimit(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)

	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Admin))
	SetListLimit(cross(cur), 50)
	uassert.Equal(t, 50, GetListLimit())

	SetListLimit(cross(cur), 1)
	uassert.PanicsWithMessage(t, cur, "count exceeds listLimit (max: 1)", func() {
		ListByOwner(equipmentTest.Owner, 1, 2)
	})

	uassert.AbortsWithMessage(t, cur, "limit must be at least 1", func() {
		SetListLimit(cross(cur), 0)
	})
	uassert.AbortsWithMessage(t, cur, "limit must be at least 1", func() {
		SetListLimit(cross(cur), -1)
	})

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})

	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/equipment_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})
}

func TestSetMinterRealm(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	minterPath := "gno.land/r/example/equipment_minter"
	minter := testing.NewCodeRealm(minterPath)
	minterAddr := minter.Address()

	uassert.Equal(t, minterAddr.String(), chain.PackageAddress(minterPath).String())
	uassert.Equal(t, false, IsMinterRealm(minterAddr))

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetMinterRealm(cross(cur), minterPath)
	})

	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Admin))
	uassert.AbortsWithMessage(t, cur, "package path is required", func() {
		SetMinterRealm(cross(cur), "")
	})
	uassert.AbortsWithMessage(t, cur, "invalid package path", func() {
		SetMinterRealm(cross(cur), "gno.land/p/akkadia/beta/equipment")
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

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/equipment_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetMinterRealm(cross(cur), minterPath)
	})
}

func TestMintFromRealm(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	minter := testing.NewCodeRealm("gno.land/r/example/equipment_minter")
	unregistered := testing.NewCodeRealm("gno.land/r/example/equipment_minter_other")

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	uassert.AbortsWithMessage(t, cur, "user calls not allowed: function must be called by a realm", func() {
		MintFromRealm(cross(cur), equipmentTest.Owner, 0, "", "")
	})

	testing.SetRealm(unregistered)
	uassert.AbortsWithMessage(t, cur, "minter realm required", func() {
		MintFromRealm(cross(cur), equipmentTest.Owner, 0, "", "")
	})

	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Admin))
	SetMinterRealm(cross(cur), "gno.land/r/example/equipment_minter")

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(minter)
	MintFromRealm(cross(cur), equipmentTest.Owner, 1101000, "enhancement", "3")
	uassert.Equal(t, uint64(1), GetLatestTokenID())
	uassert.Equal(t, equipmentTest.Owner, OwnerOf(1))
	uassert.Equal(t, "1101000", GetMetadata(1)["definitionId"])
	uassert.Equal(t, "3", GetMetadata(1)["enhancement"])
	uassert.True(t, GetMetadata(1)[createdAtKey] != "")
	uassert.Equal(t, 1, GetOwnedCount(equipmentTest.Owner))

	uassert.AbortsWithMessage(t, cur, "equipment recipient must be origin caller", func() {
		MintFromRealm(cross(cur), equipmentTest.Other, 0, "", "")
	})
	uassert.Equal(t, int64(1), BalanceOf(equipmentTest.Owner))

	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	MintFromRealm(cross(cur), equipmentTest.Owner, 1101001, "", "")
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, uint64(2), GetLatestTokenID())
	uassert.Equal(t, equipmentTest.Owner, OwnerOf(2))
}

func TestBurnFromRealm(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	minter := testing.NewCodeRealm("gno.land/r/example/equipment_minter")

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 0, "", "")
	Mint(cross(cur), equipmentTest.Other, 0, "", "")

	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Admin))
	SetMinterRealm(cross(cur), "gno.land/r/example/equipment_minter")

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	uassert.AbortsWithMessage(t, cur, "user calls not allowed: function must be called by a realm", func() {
		BurnFromRealm(cross(cur), 1)
	})

	testing.SetRealm(minter)
	uassert.AbortsWithMessage(t, cur, "equipment owner must be origin caller", func() {
		BurnFromRealm(cross(cur), 2)
	})
	uassert.Equal(t, equipmentTest.Other, OwnerOf(2))

	BurnFromRealm(cross(cur), 1)
	uassert.Equal(t, int64(0), BalanceOf(equipmentTest.Owner))
	uassert.PanicsWithMessage(t, cur, "equipment metadata not found: 1", func() {
		GetMetadata(1)
	})

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 1101000, "", "")

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(minter)
	uassert.AbortsWithMessage(t, cur, "reserved key: definitionId", func() {
		MintFromRealm(cross(cur), equipmentTest.Owner, 1, "definitionId", "1")
	})
	uassert.Equal(t, equipmentTest.Owner, OwnerOf(3))
	uassert.Equal(t, 1, GetOwnedCount(equipmentTest.Owner))
	uassert.PanicsWithMessage(t, cur, "equipment metadata not found: 4", func() {
		GetMetadata(4)
	})

	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Admin))
	UnsetMinterRealm(cross(cur), "gno.land/r/example/equipment_minter")
	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(minter)
	uassert.AbortsWithMessage(t, cur, "minter realm required", func() {
		BurnFromRealm(cross(cur), 3)
	})
	uassert.Equal(t, equipmentTest.Owner, OwnerOf(3))
}

func TestSetMetadata(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 1101000, "enhancement,note", "3,a%2Cb")
	createdAt := GetMetadata(1)[createdAtKey]
	uassert.True(t, createdAt != "")
	SetMetadata(cross(cur), 1, "enhancement", "4")
	meta := GetMetadata(1)
	uassert.Equal(t, "1101000", meta["definitionId"])
	uassert.Equal(t, "4", meta["enhancement"])
	uassert.Equal(t, createdAt, meta[createdAtKey])
	uassert.Equal(t, 3, len(meta))
	uassert.Equal(t, "4", ListByOwner(equipmentTest.Owner, 1, 1)[0]["enhancement"])
	meta["enhancement"] = "hacked"
	uassert.Equal(t, "4", GetMetadata(1)["enhancement"])

	uassert.AbortsWithMessage(t, cur, "reserved key: definitionId", func() {
		SetMetadata(cross(cur), 1, "definitionId", "9")
	})
	uassert.AbortsWithMessage(t, cur, "reserved key: created_at", func() {
		SetMetadata(cross(cur), 1, "created_at", "1")
	})
	uassert.AbortsWithMessage(t, cur, "equipment metadata not found: 2", func() {
		SetMetadata(cross(cur), 2, "enhancement", "1")
	})
	uassert.Equal(t, "1101000", GetMetadata(1)["definitionId"])

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		SetMetadata(cross(cur), 1, "enhancement", "5")
	})

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/equipment_relay"))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		SetMetadata(cross(cur), 1, "enhancement", "5")
	})
}

func TestSetMetadataFromRealm(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	minterPath := "gno.land/r/example/equipment_minter"
	minter := testing.NewCodeRealm(minterPath)

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 1101000, "enhancement", "3")
	Mint(cross(cur), equipmentTest.Other, 1101001, "enhancement", "1")

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Owner))
	uassert.AbortsWithMessage(t, cur, "user calls not allowed: function must be called by a realm", func() {
		SetMetadataFromRealm(cross(cur), 1, "enhancement", "4")
	})

	testing.SetRealm(minter)
	uassert.AbortsWithMessage(t, cur, "minter realm required", func() {
		SetMetadataFromRealm(cross(cur), 1, "enhancement", "4")
	})

	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Admin))
	SetMinterRealm(cross(cur), minterPath)

	testing.SetOriginCaller(equipmentTest.Owner)
	testing.SetRealm(minter)
	uassert.AbortsWithMessage(t, cur, "equipment owner must be origin caller", func() {
		SetMetadataFromRealm(cross(cur), 2, "enhancement", "9")
	})
	uassert.Equal(t, "1", GetMetadata(2)["enhancement"])

	createdAt := GetMetadata(1)[createdAtKey]
	SetMetadataFromRealm(cross(cur), 1, "enhancement", "4")
	uassert.Equal(t, "1101000", GetMetadata(1)["definitionId"])
	uassert.Equal(t, "4", GetMetadata(1)["enhancement"])
	uassert.Equal(t, createdAt, GetMetadata(1)[createdAtKey])

	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	SetMetadataFromRealm(cross(cur), 1, "enhancement", "5")
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, "5", GetMetadata(1)["enhancement"])
}
