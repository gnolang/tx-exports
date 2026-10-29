package lziface

import (
	"chain"

	"crypto/bech32"

	"gno.land/p/nt/ufmt/v0"
)

func Bytes32ToAddress(bz32 [32]byte) address {
	bz20 := bz32[12:]
	encoded, err := bech32.EncodeFromBase256("g", bz20)
	if err != nil {
		panic("bech32 encode failed: " + err.Error())
	}
	return address(encoded)
}

func AddressToBytes32(addr address) [32]byte {
	_, bz, err := bech32.DecodeToBase256(string(addr))
	if err != nil {
		panic("invalid bech32: " + err.Error())
	}
	return MakeBytes32(bz)
}

func PkgPathToLZAddress(pkgPath string) [32]byte {
	addr := chain.PackageAddress(pkgPath)
	return AddressToBytes32(addr)
}

func MakeBytes32(bz []byte) [32]byte {
	if len(bz) > 32 {
		panic(ufmt.Sprintf("expected length <= 32, got %d", len(bz)))
	}
	bz32 := [32]byte{}
	copy(bz32[32-len(bz):], bz)
	return bz32
}

