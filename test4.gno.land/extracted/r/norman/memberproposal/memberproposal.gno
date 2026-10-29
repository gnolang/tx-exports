package proposal

import (
	"gno.land/p/demo/dao"
	"gno.land/p/demo/membstore"
	govdao "gno.land/r/gov/dao/v2"
)

func init() {
	changesFn := func() []membstore.Member {
		return []membstore.Member{{
			Address:     "g16n55jt73sl8s5kl3z5ahrf0qrlxp47n205j9ex",
			VotingPower: 1,
		}}
	}

	executor := govdao.NewMemberPropExecutor(changesFn)

	description := "Proposal to add the shared Teritori address as member with power 1 to allow other Teritori members to create proposals"

	prop := dao.ProposalRequest{
		Description: description,
		Executor:    executor,
	}

	govdao.Propose(prop)
}
