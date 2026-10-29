package proposal

import (
	"std"

	"gno.land/p/demo/dao"
	govdao "gno.land/r/gov/dao/v2"
	"gno.land/p/demo/membstore"
)

func init() {
	changesFn := func() []membstore.Member {
		return []membstore.Member{
			{
				Address: std.Address("g1sw5xklxjjuv0yvuxy5f5s3l3mnj0nqq626a9wr"),
				VotingPower: 10,
			},
		}
	}

	// Grab the executor for the membstore changes
	executor := govdao.NewMemberPropExecutor(changesFn)

	// Create a description
	description := "Proposal to add Albert Le Batteux to the GovDAO"

	prop := dao.ProposalRequest{
		Description: description,
		Executor:    executor,
	}

	govdao.Propose(prop)
}