package tavern_offers

import (
	"gno.land/r/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/tavern_v1/guardians"
	stamps "gno.land/r/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/tavern_v1/tavern_stamps"
)

// Only reviewed NFT entry points may participate in settlement.
func ownerOf(collection, id string) address {
	switch collection {
	case "guardians":
		return guardians.OwnerOf(id)
	case "stamps":
		return stamps.OwnerOf(id)
	default:
		panic("unsupported collection")
	}
}

func deliver(cur realm, collection, id string, to address) {
	switch collection {
	case "guardians":
		guardians.TransferFrom(cross(cur), Address(), to, id)
	case "stamps":
		stamps.TransferFrom(cross(cur), Address(), to, id)
	default:
		panic("unsupported collection")
	}
}

func royalty(collection, id string, gross int64) (address, int64) {
	if collection == "guardians" {
		return guardians.RoyaltyInfo(id, gross)
	}
	if collection == "stamps" {
		return address(""), 0
	}
	panic("unsupported collection")
}
