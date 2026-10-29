package proposal

import (
	"std"

	"gno.land/p/demo/dao"
	pVals "gno.land/p/sys/validators"
	govdao "gno.land/r/gov/dao/v2"
	validators "gno.land/r/sys/validators/v2"
)

func init() {
	changesFn := func() []pVals.Validator {
		return []pVals.Validator{
			{
				Address:     std.Address("g1ut590acnamvhkrh4qz6dz9zt9e3hyu499u0gvl"),                                               // change with your address
				PubKey:      "gpub1pggj7ard9eg82cjtv4u52epjx56nzwgjyg9zq2gncppkfzmx7s22mn60mf0uxzzpl23yx97hwmwm8yc6lupepqqnlexfch", // change with your public key
				VotingPower: 1,                                                                                                     // leave this at 1
			},
		}
	}

	// Grab the executor for the valset changes
	executor := validators.NewPropExecutor(changesFn)

	// Create a description
	description := "Proposal to add Berty to the test4 validator set. These are our hackerspace issues: https://github.com/gnolang/hackerspace/issues/28 https://github.com/gnolang/hackerspace/issues/51 https://github.com/gnolang/hackerspace/issues/92"

	prop := dao.ProposalRequest{
		Description: description,
		Executor:    executor,
	}

	govdao.Propose(prop)
}
