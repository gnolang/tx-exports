package teritorivalproposal

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
				Address:     std.Address("g1k9lqyvzjn2mnjyf3gxsk3uw3r9785cy6dfcmqz"),
				PubKey:      "gpub1pggj7ard9eg82cjtv4u52epjx56nzwgjyg9zpaeejysrx0n3pvz0g54yjg3dg234dprual5xqcy30ulfr84lyzrxvjqj0l",
				VotingPower: 1, // leave this at 1
			},
		}
	}

	// Create the executor with the changes
	executor := validators.NewPropExecutor(changesFn)

	// Create a descriptive comment, you can use Markdown
	comment := "Proposal to add Teritori's validator. Contributions can be found at: https://github.com/gnolang/hackerspace/issues/7"

	// Propose the changes to the govdao
	govdao.Propose(comment, executor)
}
