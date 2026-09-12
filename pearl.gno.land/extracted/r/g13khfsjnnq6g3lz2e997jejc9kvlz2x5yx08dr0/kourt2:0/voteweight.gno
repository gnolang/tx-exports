package kourt2
func votingWeight(c *Court, who address, at uint32) (w, snapshot int64) {
	snapshot = c.coin.PastVotes(who, at)
	w = snapshot
	if held := c.coin.BalanceOf(who); held < w {
		w = held
	}
	if w < 0 {
		w = 0
	}
	return w, snapshot
}
func voteCap(c *Court, who address) int64 { return c.coin.BalanceOf(who) }
func ClaimVoteWeightOf(courtSlug string, who address, claimID uint64) (verdict, quality int64) {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.disputeOpen {
		verdict, _ = votingWeight(c, who, c.gov.EpochOf(cs.proposalID))
	}
	return verdict, quality
}
func ElectionVoteWeightOf(courtSlug string, who address) int64 {
	c := mustCourt(courtSlug)
	if c.mod == nil || c.mod.election == nil || c.mod.election.resolved {
		return 0
	}
	e := c.mod.election
	if prior := e.voters.Get(who.String()); prior != nil {
		return prior.(int64)
	}
	w, _ := votingWeight(c, who, e.epoch)
	return w
}
func VoteWeightWhy(courtSlug string, who address, claimID uint64) (verdict, quality string) {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	verdict = "no verdict vote is open on this claim"
	if cs.disputeOpen {
		verdict = whyWeighed(c, who, c.gov.EpochOf(cs.proposalID))
	}
	quality = "the quality vote no longer exists"
	return verdict, quality
}
func whyWeighed(c *Court, who address, at uint32) string {
	w, snapshot := votingWeight(c, who, at)
	switch {
	case snapshot <= 0:
		return "you had none when this vote started; coin bought since counts in later votes"
	case w <= 0:
		return "you had some when this vote started but have none now, and your say is the smaller of the two"
	case w < snapshot:
		return "limited to what you still hold, which is less than when this vote started"
	}
	return "counted in full"
}
