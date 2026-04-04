package valopers_prop_9

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
"g15yc3kdd8jvf7pxc6pgt3qgdf0sk2p8knth0ldf", // Ruangnode
"g1e9f40j7twds9ccg4up09dc6jndhfnqgz8ckuth", // Itrocket
"g1sgu52u6hfffg9tyck7v3zgd27hhv2paf9rgamr", // Apollo
"g13k6u5n6cahek2xg0k23kmatpt36dhfrdl62v27", // Chiter in Cosmos
"g1v3xmq6m8k9cpwyz4ghdah6eq8cc8hlczelexqp", // KaLaMuC
"g18wr9fq2wpnnn4xutngvrwk9rlzru7m05t5pajy", // Hazen Network
"g10n842agrhkpzlur5ghu9apcqvxznzq6rdepc05", // HusoNode
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
