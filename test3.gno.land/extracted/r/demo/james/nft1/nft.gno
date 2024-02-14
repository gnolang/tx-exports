package test721

import (
	"std"

	"gno.land/p/demo/grc/grc721"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	admin std.Address = "g14q20ep8nmrlxkwtaclyujruk4cg6w584qhte96"
	test               = grc721.NewBasicNFT("TestNFT", "TNFT")
)

func init() {
	mintNNFT(admin, 10)                                     // @administrator (10)
	mintNNFT("g1var589z07ppjsjd24ukm4uguzwdt0tw7g47cgm", 5) // @hariom (5)
}

func mintNNFT(owner std.Address, n uint64) {
	count := test.TokenCount()
	for i := count; i < count+n; i++ {
		tid := grc721.TokenID(ufmt.Sprintf("%d", i))
		test.Mint(owner, tid)
	}
}

// Getters

func BalanceOf(user users.AddressOrName) uint64 {
	balance, err := test.BalanceOf(user.Resolve())
	if err != nil {
		panic(err)
	}

	return balance
}

func OwnerOf(tid grc721.TokenID) std.Address {
	owner, err := test.OwnerOf(tid)
	if err != nil {
		panic(err)
	}

	return owner
}

func IsApprovedForAll(owner, user users.AddressOrName) bool {
	return test.IsApprovedForAll(owner.Resolve(), user.Resolve())
}

func GetApproved(tid grc721.TokenID) std.Address {
	addr, err := test.GetApproved(tid)
	if err != nil {
		panic(err)
	}

	return addr
}

// Setters

func Approve(user users.AddressOrName, tid grc721.TokenID) {
	err := test.Approve(user.Resolve(), tid)
	if err != nil {
		panic(err)
	}
}

func SetApprovalForAll(user users.AddressOrName, approved bool) {
	err := test.SetApprovalForAll(user.Resolve(), approved)
	if err != nil {
		panic(err)
	}
}

func TransferFrom(from, to users.AddressOrName, tid grc721.TokenID) {
	err := test.TransferFrom(from.Resolve(), to.Resolve(), tid)
	if err != nil {
		panic(err)
	}
}

// Admin

func Mint(to users.AddressOrName, tid grc721.TokenID) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := test.Mint(to.Resolve(), tid)
	if err != nil {
		panic(err)
	}
}

func Burn(tid grc721.TokenID) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := test.Burn(tid)
	if err != nil {
		panic(err)
	}
}

// Render

func Render(path string) string {
	switch {
	case path == "":
		return test.RenderHome()
	default:
		return "404\n"
	}
}

// Util

func assertIsAdmin(address std.Address) {
	if address != admin {
		panic("restricted access")
	}
}
