package valopers_prop_15

import (
	"strings"

	"gno.land/p/nt/ownable"
	"gno.land/p/sys/validators"
	"gno.land/r/gnops/valopers"
)

var owner = ownable.New()

// SetInitialVals updates the validator addresses for the batch
func SetInitialVals(_ realm, newVals string) {
	owner.AssertOwnedByCurrent()

	initialVals = strings.Split(newVals, ",")
}

var initialVals = []string{
	"g1ufqycj52c387cm0t6ayxh9qwkypp6s06877k0n", // AviaOne
	"g1vtccreqzek20a5u32pfaa3xemhdw7p7zj5szff", // VALIDARIOS
	"g1222c3qnzny0e6spfdhr59386tlfhlatnre3ew7", // CoreStake
	"g15j9c27s2j4hugudmn54x0tvlngdldl66l06u6e", // Provalidator
}

// Callback is the main importable GovDAO prop callback
func Callback() []validators.Validator {
	vals := make([]validators.Validator, 0, len(initialVals))

	for _, addr := range initialVals {
		profile := valopers.GetByAddr(address(addr))

		// Check if the profile is active
		if !profile.KeepRunning {
			continue
		}

		val := validators.Validator{
			Address:     profile.Address,
			PubKey:      profile.PubKey,
			VotingPower: 1,
		}

		vals = append(vals, val)
	}

	return vals
}
