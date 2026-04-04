package valopers_prop_10

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
	"g18nnlcy0efq92wxr000yk3zv3adh70v59lva86y", // Trace
	"g1rgwtaert8vguwq2dl7p7uu2g04x8yfvmf6heey", // Tecnodes
	"g1yd75tc52xfm8zyllngzvul9cdum6med2par6h4", // KonsorTech
	"g1shpyvk059fcjwvdmdylg2adcx73rm6lgmlv2rf", // Shazoes
	"g16827gpxn7sfyd34w6v2sy5z6749xp5x6kzl2te", // OshVanK
	"g10n842agrhkpzlur5ghu9apcqvxznzq6rdepc05", // HusoNode
	"g1y6y2ttkdnmqd8addnsd8qcpvfu9rn677ywjhmz", // Vinjan.Inc
	"g163nzpwjpmesnxmq75u8sa8k98xjanf3nktsljq", // Kleomedes
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
