package valopers_prop_14_remove

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
	"g1p8gjus6ugxr92c9jvcg9evqg99nyqj67gt5xz6", // Oneiric Stake - WRONG ADDR
	"g1fk2unyxhjls9lnmyka48qs8ys3ggwkm0cwx8fy", // Inter Blockchain Services - WRONG ADDR 
	"g10n842agrhkpzlur5ghu9apcqvxznzq6rdepc05", // HusoNode - WRONG ADDR
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
			VotingPower: 0,
		}

		vals = append(vals, val)
	}

	return vals
}
