package valopers_prop_4

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
	"g1p8gjus6ugxr92c9jvcg9evqg99nyqj67gt5xz6", // Oneiric Stake
	"g1zmua93u53na9xsvtmlh5d8p7pm0w7p52ehewc9", // PRO Delegators
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
