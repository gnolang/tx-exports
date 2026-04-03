package valopers_prop_6

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
	"g1e5sxezpafa8lcv5xu3nmw4plz30mnepq2wv9xs", // AviaOne
	"g1a4d5cn9nqh6m3thkvmelf756sjap6g3drrnx9m", // LuckyStar
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
