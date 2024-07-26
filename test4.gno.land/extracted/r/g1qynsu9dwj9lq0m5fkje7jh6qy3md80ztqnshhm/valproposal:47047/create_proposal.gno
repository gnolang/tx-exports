package valproposal

import (
	"std"

	pVals "gno.land/p/sys/validators"
	govdao "gno.land/r/gov/dao"
	"gno.land/r/sys/validators"
)

func init() {
	changesFn := func() []pVals.Validator {
		return []pVals.Validator{
			{
				Address:     std.Address("g1ut590acnamvhkrh4qz6dz9zt9e3hyu499u0gvl"),
				PubKey:      "gpub1pggj7ard9eg82cjtv4u52epjx56nzwgjyg9zq2gncppkfzmx7s22mn60mf0uxzzpl23yx97hwmwm8yc6lupepqqnlexfch",
				VotingPower: 1, // leave this at 1
			},
		}
	}

	// Create the executor with the changes
	executor := validators.NewPropExecutor(changesFn)

	// Create a descriptive comment, you can use Markdown
	comment := "Proposal to add our validator. Contributions can be found at: https://github.com/gnolang/hackerspace/issues/51 . Earlier contributions at: https://github.com/gnolang/hackerspace/issues/28"

	// Propose the changes to the govdao
	govdao.Propose(comment, executor)
}
