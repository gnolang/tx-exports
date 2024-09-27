package gnft

import (
	"std"

	"gno.land/p/demo/grc/grc721"
	"gno.land/r/demo/users"

	pusers "gno.land/p/demo/users"

	"gno.land/p/demo/ufmt"
)

var (
	admin std.Address = "g1y3uyaa63sjxvah2cx3c2usavwvx97kl8m2v7ye" // deployed position contract
	gnft              = grc721.NewBasicNFT("GNOSWAP NFT", "GNFT")
)

func init() {
	tid := grc721.TokenID("99")
	err := gnft.Mint(admin, tid)
	if err != nil {
		panic(err.Error())
	}

	tokenRaw := getImageBase64(tid)
	gnft.SetTokenURI(tid, grc721.TokenURI(tokenRaw))
}

func AMint() {
	strTid := ufmt.Sprintf("%d", TotalSupply()+1)
	tid := grc721.TokenID(strTid)
	err := gnft.Mint(admin, tid)
	if err != nil {
		panic(err.Error())
	}

	tokenRaw := getImageBase64(tid)
	gnft.SetTokenURI(tid, grc721.TokenURI(tokenRaw))

}

// Getters
func TotalSupply() uint64 {
	return gnft.TokenCount()
}

func GetTokenURI(tid grc721.TokenID) string {
	uri, err := gnft.TokenURI(tid)
	if err != nil {
		panic(err.Error())
	}

	return string(uri)
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

	tokenRaw := getImageBase64(tid)
	gnft.SetTokenURI(tid, grc721.TokenURI(tokenRaw))
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
