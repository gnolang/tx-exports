package gnft

import (
	"std"

	"gno.land/p/demo/grc/grc721"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"

	pusers "gno.land/p/demo/users"
)

var (
	admin std.Address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
	gnft              = grc721.NewBasicNFT("NFT", "GFT")

	nftImage = make(map[grc721.TokenID]string)
)

func init() {
	// NEW_GSA
	gsa := std.Address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	mintNNFT(gsa, 1)
}

func mintNNFT(owner std.Address, n uint64) {
	count := gnft.TokenCount()
	for i := count; i < count+n; i++ {
		tid := grc721.TokenID(ufmt.Sprintf("%d", i))
		gnft.Mint(owner, tid)
	}
}

// Getters
func TotalSupply() uint64 {
	return gnft.TokenCount()
}

func BalanceOf(user pusers.AddressOrName) uint64 {
	balance, err := gnft.BalanceOf(users.Resolve(user))
	if err != nil {
		panic(err.Error())
	}

	return balance
}

func OwnerOf(tid grc721.TokenID) std.Address {
	owner, err := gnft.OwnerOf(tid)
	if err != nil {
		panic(err.Error())
	}

	return owner
}

func IsApprovedForAll(owner, user pusers.AddressOrName) bool {
	return gnft.IsApprovedForAll(users.Resolve(owner), users.Resolve(user))
}

func GetApproved(tid grc721.TokenID) (std.Address, bool) {
	addr, err := gnft.GetApproved(tid)
	if err != nil {
		return "", false
	}

	return addr, true
}

// Setters

func Approve(user pusers.AddressOrName, tid grc721.TokenID) {
	err := gnft.Approve(users.Resolve(user), tid)
	if err != nil {
		panic(err.Error())
	}
}

func SetApprovalForAll(user pusers.AddressOrName, approved bool) {
	err := gnft.SetApprovalForAll(users.Resolve(user), approved)
	if err != nil {
		panic(err.Error())
	}
}

func TransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := gnft.TransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err.Error())
	}
}

// Admin

func Mint(to pusers.AddressOrName, tid grc721.TokenID) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := gnft.Mint(users.Resolve(to), tid)
	if err != nil {
		panic(err.Error())
	}

	nftImage[tid] = getImageBase64(tid)
}

func Burn(tid grc721.TokenID) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := gnft.Burn(tid)
	if err != nil {
		panic(err.Error())
	}
}

func SetAdmin(newAdmin pusers.AddressOrName) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	admin = users.Resolve(newAdmin)
}

// Render

func Render(path string) string {
	switch {
	case path == "":
		return gnft.RenderHome()
	default:
		return "404\n"
	}
}

func RenderImage(tid grc721.TokenID) string {
	image, ok := nftImage[tid]
	if !ok {
		return ""
	}

	return image
}

// Util
func assertIsAdmin(address std.Address) {
	if address != admin {
		panic("restricted access")
	}
}

func Exists(tid grc721.TokenID) bool {
	_, err := gnft.OwnerOf(tid)
	if err != nil {
		return false
	}

	return true
}
