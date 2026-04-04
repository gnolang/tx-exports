package valopers_prop_11

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
	"g1uax59n7fnnm70mnxlldsremz06rsfuct75dzps", // dnsarz
	"g1jyqu4jq63v6xvc7ykehhhdvhrkxhh2glha065z", // EquinoxDao
	"g1rs24l3czq53u9vsxghz4t26t99k4tzma0ull55", // ChainTools
	"g1jzhxzmuh5vwvpw5cgea07lp3lm39rj8tmx240g", // Nodeist
	"g1nhg60gtqlrp4y0t7jmupggcg26f7y9mtgw099e", // Curiosity Nodes
	"g1wjrkxvx2heajm9dk7cprjs7872km2aa0fy0eym", // Ubik Capital
	"g1taf2x9vrvga5edd2e307ecdzymqf0r9gcx5cav", // BZE Community
	"g1rsrctfwmzxschvkf6e6dtawurx0z700tdgczuw", // Plantree
	"g1533w0xpq76dws5tvggfg2u9du6ysnlhgys4z30", // MictoNode
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
