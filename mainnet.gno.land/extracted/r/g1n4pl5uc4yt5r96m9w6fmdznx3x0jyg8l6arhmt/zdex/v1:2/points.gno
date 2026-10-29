package zdex

import "chain"

func maybeRollEpoch() {
	h := height()
	if epochBlocks <= 0 {
		epochBlocks = defaultEpochBlocks
	}
	if epoch == 0 {
		epoch = 1
		epochEnd = h + epochBlocks
		return
	}
	if h < epochEnd {
		return
	}
	carry := closedPot
	closedID = epoch
	closedPts = epochPts
	closedPot = epochPot
	epoch++
	epochPts = 0
	epochPot = carry
	epochEnd = h + epochBlocks
	chain.Emit("Epoch", "id", itoa(int64(epoch)), "closedPot", itoa(closedPot), "closedPts", itoa(closedPts))
}

func getScore(owner address) *Score {
	v := scores.Get(owner.String())
	if v == nil {
		s := &Score{}
		scores.Set(owner.String(), s)
		return s
	}
	return v.(*Score)
}

func syncScore(s *Score) {
	maybeRollEpoch()
	if s.EpochID == epoch {
		return
	}
	if s.EpochID == closedID {
		s.Closed = s.Epoch
	} else {
		s.Closed = 0
	}
	s.Epoch = 0
	s.EpochID = epoch
}

func addPoints(owner address, pts int64) {
	if pts <= 0 {
		return
	}
	maybeRollEpoch()
	s := getScore(owner)
	syncScore(s)
	s.Epoch = add64(s.Epoch, pts)
	s.Life = add64(s.Life, pts)
	epochPts = add64(epochPts, pts)
}

func harvestLP(p *Pool, owner address) {
	st := getPos(p.ID, owner)
	if st == nil || st.LP <= 0 {
		return
	}
	acc := MulDiv(st.LP, p.AccPoints, ptsScale)
	if acc > st.RewardDebt {
		addPoints(owner, acc-st.RewardDebt)
	}
	st.RewardDebt = acc
}

func creditSwapPoints(p *Pool, trader address, volU int64, fs feeSplit, ugnotSide bool) {
	_ = trader
	_ = volU
	if ugnotSide {
		p.AccruedCreatorU = add64(p.AccruedCreatorU, fs.creator)
		p.AccruedProtocolU = add64(p.AccruedProtocolU, fs.protocol)
	} else {
		p.AccruedCreatorT = add64(p.AccruedCreatorT, fs.creator)
		p.AccruedProtocolT = add64(p.AccruedProtocolT, fs.protocol)
	}
}

// HarvestPoints settles LP points for a pool without depositing. No extra stake.
func HarvestPoints(cur realm, poolID string) int64 {
	panic("zdex: epoch disabled")
}

func HarvestAll(cur realm) int64 {
	panic("zdex: epoch disabled")
}

func ClaimFeeShare(cur realm) int64 {
	panic("zdex: epoch disabled")
}

func PointsOf(owner address) (life, epochPtsUser, closedPtsUser int64) {
	v := scores.Get(owner.String())
	if v == nil {
		return 0, 0, 0
	}
	s := v.(*Score)
	if s.EpochID == epoch {
		return s.Life, s.Epoch, s.Closed
	}
	if s.EpochID == closedID {
		return s.Life, 0, s.Epoch
	}
	return s.Life, 0, 0
}

func ClaimableFeeShare(owner address) int64 {
	if closedID == 0 || closedPot <= 0 || closedPts <= 0 {
		return 0
	}
	v := scores.Get(owner.String())
	if v == nil {
		return 0
	}
	s := v.(*Score)
	if s.ClaimedID == closedID {
		return 0
	}
	closed := s.Closed
	if s.EpochID == closedID {
		closed = s.Epoch
	} else if s.EpochID != epoch {
		return 0
	}
	return MulDiv(closed, closedPot, closedPts)
}

func EpochInfo() (id, endH, pot, pts, cID, cPot, cPts int64) {
	return int64(epoch), epochEnd, epochPot, epochPts, int64(closedID), closedPot, closedPts
}

func SetEpochBlocks(cur realm, n int64) {
	mustOwner(cur)
	require(n >= 10, "zdex: epoch too short")
	epochBlocks = n
	h := height()
	if epoch > 0 && epochEnd > h+n {
		epochEnd = h + n
	}
}

func SetFeeShareBps(cur realm, bps int64) {
	mustOwner(cur)
	require(bps >= 0 && bps <= bpsDen, "zdex: fee share")
	feeShareBps = bps
}
