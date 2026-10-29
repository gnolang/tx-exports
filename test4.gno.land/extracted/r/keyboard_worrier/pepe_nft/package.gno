package pepe_nft

import (
	"std"

	"gno.land/p/demo/grc/grc721"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"

	pusers "gno.land/p/demo/users"
)

var (
	admin std.Address = "g13qpel38unrma0nyrj29tr903pq7dpeecsmlu8z"
	pepe              = grc721.NewBasicNFT("PepeNFT", "PEPE")
)

func init() {
	mintNNFT(admin, 20)                                     // @administrator (20)
	mintNNFT("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5", 5) // @hariom (5)
}

func mintNNFT(owner std.Address, n uint64) {
	count := pepe.TokenCount()
	for i := count; i < count+n; i++ {
		tid := grc721.TokenID(ufmt.Sprintf("%d", i))
		pepe.Mint(owner, tid)
	}
}

// Getters

func BalanceOf(user pusers.AddressOrName) uint64 {
	balance, err := pepe.BalanceOf(users.Resolve(user))
	if err != nil {
		panic(err)
	}

	return balance
}

func OwnerOf(tid grc721.TokenID) std.Address {
	owner, err := pepe.OwnerOf(tid)
	if err != nil {
		panic(err)
	}

	return owner
}

func IsApprovedForAll(owner, user pusers.AddressOrName) bool {
	return pepe.IsApprovedForAll(users.Resolve(owner), users.Resolve(user))
}

func GetApproved(tid grc721.TokenID) std.Address {
	addr, err := pepe.GetApproved(tid)
	if err != nil {
		panic(err)
	}

	return addr
}

// Setters

func Approve(user pusers.AddressOrName, tid grc721.TokenID) {
	err := pepe.Approve(users.Resolve(user), tid)
	if err != nil {
		panic(err)
	}
}

func SetApprovalForAll(user pusers.AddressOrName, approved bool) {
	err := pepe.SetApprovalForAll(users.Resolve(user), approved)
	if err != nil {
		panic(err)
	}
}

func TransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := pepe.TransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

// Admin

func Mint(to pusers.AddressOrName, tid grc721.TokenID) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := pepe.Mint(users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func Burn(tid grc721.TokenID) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := pepe.Burn(tid)
	if err != nil {
		panic(err)
	}
}

// Render

func Render(path string) string {
	switch {
	case path == "":
		return pepe.RenderHome()
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
