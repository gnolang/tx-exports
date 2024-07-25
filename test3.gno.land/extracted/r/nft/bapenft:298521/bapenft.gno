package bapenft

import (
    "std"

    "gno.land/p/demo/grc/grc721"
    "gno.land/r/demo/users"
)

var (
    admin std.Address = "g1v664qx78zhv2edtx6ypdylfpafrqjz8g2rlaea"
    bapenft = grc721.NewBasicNFT("bapenft", "BNFT")
)

func init() {
    mintNNFT(admin, 10) // @administrator (supply = 10)
}

func mintNNFT(owner std.Address, n uint64) {
    count := bapenft.TokenCount()
    for i := count; i < count+n; i++ {
        tid := grc721.TokenID(ufmt.Sprintf("%d", i))
        bapenft.Mint(owner, tid)
    }
}

func BalanceOf(user users.AddressOrName) uint64 {
    balance, err := bapenft.BalanceOf(user.Resolve())
    if err != nil {
        panic(err)
    }

    return balance
}

func OwnerOf(tid grc721.TokenID) std.Address {
    owner, err := bapenft.OwnerOf(tid)
    if err != nil {
        panic(err)
    }

    return owner
}

func IsApprovedForAll(owner, user users.AddressOrName) bool {
    return bapenft.IsApprovedForAll(owner.Resolve(), user.Resolve())
}

func GetApproved(tid grc721.TokenID) std.Address {
    addr, err := bapenft.GetApproved(tid)
    if err != nil {
        panic(err)
    }

    return addr
}

func Approve(user users.AddressOrName, tid grc721.TokenID) {
    err := bapenft.Approve(user.Resolve(), tid)
    if err != nil {
        panic(err)
    }
}

func SetApprovalForAll(user users.AddressOrName, approved bool) {
    err := bapenft.SetApprovalForAll(user.Resolve(), approved)
    if err != nil {
        panic(err)
    }
}

func TransferFrom(from, to users.AddressOrName, tid grc721.TokenID) {
    err := bapenft.TransferFrom(from.Resolve(), to.Resolve(), tid)
    if err != nil {
        panic(err)
    }
}

func Mint(to users.AddressOrName, tid grc721.TokenID) {
    caller := std.PrevRealm().Addr()
    assertIsAdmin(caller)
    err := bapenft.Mint(to.Resolve(), tid)
    if err != nil {
        panic(err)
    }
}

func Burn(tid grc721.TokenID) {
    caller := std.PrevRealm().Addr()
    assertIsAdmin(caller)
    err := bapenft.Burn(tid)
    if err != nil {
        panic(err)
    }
}

func Render(path string) string {
    switch {
    case path == "":
        return bapenft.RenderHome()
    default:
        return "404\n"
    }
}

func assertIsAdmin(address std.Address) {
    if address != admin {
        panic("restricted access")
    }
}