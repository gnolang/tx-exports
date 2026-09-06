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
	maybeRollEpoch()
	if ugnotSide {
		p.AccruedCreatorU = add64(p.AccruedCreatorU, fs.creator)
		if fs.protocol > 0 {
			if feeShareBps <= 0 {
				feeShareBps = defaultFeeShareBps
			}
			toUsers := MulDiv(fs.protocol, feeShareBps, bpsDen)
			p.AccruedProtocolU = add64(p.AccruedProtocolU, fs.protocol-toUsers)
			epochPot = add64(epochPot, toUsers)
		}
	} else {
		p.AccruedCreatorT = add64(p.AccruedCreatorT, fs.creator)
		p.AccruedProtocolT = add64(p.AccruedProtocolT, fs.protocol)
	}
	if volU <= 0 {
		return
	}
	addPoints(trader, volU)
	if p.TotalLP > 0 {
		p.AccPoints = add64(p.AccPoints, MulDiv(volU, ptsScale, p.TotalLP))
	}
}

// HarvestPoints settles LP points for a pool without depositing. No extra stake.
func HarvestPoints(cur realm, poolID string) int64 {
	assertNotPaused()
	p := getPool(poolID)
	owner := cur.Previous().Address()
	before := getScore(owner).Life
	harvestLP(p, owner)
	return getScore(owner).Life - before
}

// ClaimFeeShare pays last closed epoch's protocol-ugnot pot, pro-rata by points.
func ClaimFeeShare(cur realm) int64 {
	maybeRollEpoch()
	require(closedID > 0 && closedPot > 0 && closedPts > 0, "zdex: nothing to share")
	owner := cur.Previous().Address()
	s := getScore(owner)
	syncScore(s)
	require(s.ClaimedID != closedID, "zdex: already claimed")
	require(s.Closed > 0, "zdex: no epoch points")
	out := MulDiv(s.Closed, closedPot, closedPts)
	require(out > 0, "zdex: share too small")
	s.ClaimedID = closedID
	closedPot = sub64(closedPot, out)
	closedPts = sub64(closedPts, s.Closed)
	sendUgnot(0, cur, owner, out)
	chain.Emit("ClaimFeeShare", "to", owner.String(), "ugnot", itoa(out), "epoch", itoa(int64(closedID)))
	return out
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
