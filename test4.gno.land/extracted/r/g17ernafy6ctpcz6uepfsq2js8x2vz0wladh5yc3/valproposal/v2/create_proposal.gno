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
                		Address:     std.Address("g1rncfld0c9r0gzkzr9mjary5fr3sseass6ag3lf"),
                		PubKey:      "l0XwzXPqilbq54k7lUzIT4hJTUxva2TMrYVGJGyEjsc=",
                		VotingPower: 1, // leave this at 1
            		},	
		}
	}

	// Grab the executor for the valset changes
	executor := validators.NewPropExecutor(changesFn)

	// Create a description
	description := "Proposal to add rpc.irreverentsimplicity.xyz to the test4 validator set. Creator of Flippando and ZenTasktic."

	prop := dao.ProposalRequest{
		Description: description,
		Executor:    executor,
	}

	govdao.Propose(prop)
}
