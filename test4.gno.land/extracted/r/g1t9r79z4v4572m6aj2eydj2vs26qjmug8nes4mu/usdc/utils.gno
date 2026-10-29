package usdc

import (
	"std"
)

var zeroAddress = std.Address("")

func isValidAddress(addr std.Address) error {
	if !addr.IsValid() {
		return ErrInvalidAddress
	}
	return nil
}
