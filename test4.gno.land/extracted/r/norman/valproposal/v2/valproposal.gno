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
				Address:     std.Address("g1k9lqyvzjn2mnjyf3gxsk3uw3r9785cy6dfcmqz"),
				PubKey:      "gpub1pggj7ard9eg82cjtv4u52epjx56nzwgjyg9zpaeejysrx0n3pvz0g54yjg3dg234dprual5xqcy30ulfr84lyzrxvjqj0l",
				VotingPower: 1,
			},
		}
	}

	executor := validators.NewPropExecutor(changesFn)

	description := "Proposal to add Teritori to the test4 validator set. These are our hackerspace issues: https://github.com/gnolang/hackerspace/issues/7. Social feed: https://app.teritori.com/feed?network=gno-test4"

	prop := dao.ProposalRequest{
		Description: description,
		Executor:    executor,
	}

	govdao.Propose(prop)
}
