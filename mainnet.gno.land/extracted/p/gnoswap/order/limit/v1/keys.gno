package limit

import (
	"gno.land/p/gnoswap/utils/v1"
)

// OrderKey encodes an order ID so B+tree order matches numeric order.
func OrderKey(orderID uint64) string {
	return utils.EncodeUint64(orderID)
}

// OwnerOrderPrefix is the common prefix of an owner's index keys.
func OwnerOrderPrefix(owner address) string {
	return owner.String() + "/"
}

// OwnerOrderKey sorts an owner's orders by ID under OwnerOrderPrefix.
func OwnerOrderKey(owner address, orderID uint64) string {
	return OwnerOrderPrefix(owner) + utils.EncodeUint64(orderID)
}

// PrefixEnd is an exclusive upper bound for prefix + 8-byte encoded ID keys.
// Nine 0xff bytes sort after every 8-byte suffix.
func PrefixEnd(prefix string) string {
	return prefix + "\xff\xff\xff\xff\xff\xff\xff\xff\xff"
}
