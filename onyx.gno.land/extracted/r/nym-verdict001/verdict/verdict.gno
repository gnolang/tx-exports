package verdict

import (
	"chain"
	"math/overflow"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nym-verdict001/fpmm"
)

// CreateMarket deploys a new permissionless binary prediction market and seeds
// a 50/50 CPMM liquidity pool with the attached ugnot deposit.
//
// Pass disputeWindowSec = 0 to use DefaultDisputeWindow (3600s).
// EOA-only (`maketx call` with -send >= 100000ugnot).
func CreateMarket(
	cur realm,
	question string,
	description string,
	category string,
	closeTimeUnix int64,
	feeBps int64,
	disputeWindowSec int64,
) uint64 {
	deposit := requireEOAPayment(0, cur, MinInitialLiquidity)
	caller := cur.Previous().Address()

	question = strings.TrimSpace(question)
	description = strings.TrimSpace(description)
	category = strings.TrimSpace(category)

	if len(question) == 0 || len(question) > MaxQuestionLen {
		panic("invalid question length")
	}
	if len(description) > MaxDescriptionLen {
		panic("description too long")
	}
	if len(category) == 0 || len(category) > MaxCategoryLen {
		panic("invalid category length")
	}

	now := time.Now().Unix()
	if closeTimeUnix < now+MinMarketDuration || closeTimeUnix > now+MaxMarketDuration {
		panic("close time out of bounds")
	}
	if disputeWindowSec == 0 {
		disputeWindowSec = DefaultDisputeWindow
	}
	if disputeWindowSec < MinDisputeWindow || disputeWindowSec > MaxDisputeWindow {
		panic("dispute window out of bounds")
	}

	pool, err := fpmm.NewPool(deposit, feeBps)
	if err != nil {
		panic(err.Error())
	}

	nextColl, ok := overflow.Add64(totalCollateral, deposit)
	if !ok {
		panic("total collateral overflow")
	}

	id := uint64(nextMarketID.Next())
	posTree := avl.NewTree()
	posTree.Set(caller.String(), &position{
		lpShares: pool.TotalLP,
	})

	m := &market{
		id:            id,
		question:      question,
		description:   description,
		category:      category,
		creator:       caller,
		createdAt:     now,
		closeTime:     closeTimeUnix,
		disputeWindow: disputeWindowSec,
		bondAmount:    defaultBond,
		pool:          pool,
		collateral:    deposit,
		status:        StatusOpen,
		positions:     posTree,
		priceHistory: []pricePoint{
			{
				timestamp:  now,
				yesProbBps: pool.YesProbBps(),
				volume:     0,
			},
		},
	}

	markets.Set(nextMarketID.String(), m)
	totalCollateral = nextColl

	chain.Emit(
		"MarketCreated",
		"marketId", strconv.FormatUint(id, 10),
		"creator", caller.String(),
		"category", category,
		"closeTime", strconv.FormatInt(closeTimeUnix, 10),
		"feeBps", strconv.FormatInt(feeBps, 10),
		"initialLiquidity", strconv.FormatInt(deposit, 10),
	)
	return id
}

// Buy purchases YES (buyYes=true) or NO (buyYes=false) outcome shares with
// attached ugnot, reverting if fewer than minSharesOut shares are returned.
// EOA-only (`maketx call`).
func Buy(cur realm, marketID uint64, buyYes bool, minSharesOut int64) int64 {
	gross := requireEOAPayment(0, cur, 1)
	caller := cur.Previous().Address()
	m := getMarketOrPanic(marketID)

	now := time.Now().Unix()
	if m.status != StatusOpen || now >= m.closeTime {
		panic("market is closed for trading")
	}

	side := fpmm.SideNo
	if buyYes {
		side = fpmm.SideYes
	}

	nextPool, q, err := m.pool.ApplyBuy(side, gross, minSharesOut)
	if err != nil {
		panic(err.Error())
	}
	nextAcc, err := fpmm.UpdateFeeAccumulator(m.feeAcc, q.Fee, m.pool.TotalLP)
	if err != nil {
		panic(err.Error())
	}

	mColl, ok := overflow.Add64(m.collateral, q.NetCollateral)
	if !ok {
		panic("collateral overflow")
	}
	tColl, ok := overflow.Add64(totalCollateral, q.NetCollateral)
	if !ok {
		panic("total collateral overflow")
	}
	mFee, ok := overflow.Add64(m.feePool, q.Fee)
	if !ok {
		panic("fee pool overflow")
	}
	tFee, ok := overflow.Add64(totalFeePool, q.Fee)
	if !ok {
		panic("total fee pool overflow")
	}
	mVol, ok := overflow.Add64(m.totalVolume, gross)
	if !ok {
		panic("volume overflow")
	}
	tVol, ok := overflow.Add64(totalVolume, gross)
	if !ok {
		panic("total volume overflow")
	}

	pos := getOrCreatePosition(m, caller)
	m.pool = nextPool
	m.feeAcc = nextAcc
	m.collateral = mColl
	totalCollateral = tColl
	m.feePool = mFee
	totalFeePool = tFee
	m.totalVolume = mVol
	totalVolume = tVol
	m.tradeCount++
	totalTrades++

	if buyYes {
		pos.yesShares += q.SharesOut
		m.totalYesOut += q.SharesOut
	} else {
		pos.noShares += q.SharesOut
		m.totalNoOut += q.SharesOut
	}

	recordPricePoint(m, now, q.NewYesProbBps, m.totalVolume)

	chain.Emit(
		"Trade",
		"marketId", strconv.FormatUint(m.id, 10),
		"trader", caller.String(),
		"action", "buy",
		"side", side.String(),
		"collateral", strconv.FormatInt(gross, 10),
		"shares", strconv.FormatInt(q.SharesOut, 10),
		"fee", strconv.FormatInt(q.Fee, 10),
		"yesProbBps", strconv.FormatInt(q.NewYesProbBps, 10),
	)
	return q.SharesOut
}

// Sell sells sharesIn YES or NO shares back to the pool and sends net ugnot
// to the caller, reverting if output is below minCollateralOut.
func Sell(cur realm, marketID uint64, sellYes bool, sharesIn, minCollateralOut int64) int64 {
	caller := cur.Previous().Address()
	m := getMarketOrPanic(marketID)

	now := time.Now().Unix()
	if m.status != StatusOpen || now >= m.closeTime {
		panic("market is closed for trading")
	}
	if sharesIn <= 0 {
		panic("sharesIn must be positive")
	}

	pos := getPositionOrNil(m, caller)
	if pos == nil {
		panic("insufficient shares")
	}
	if sellYes {
		if pos.yesShares < sharesIn {
			panic("insufficient YES shares")
		}
	} else {
		if pos.noShares < sharesIn {
			panic("insufficient NO shares")
		}
	}

	side := fpmm.SideNo
	if sellYes {
		side = fpmm.SideYes
	}

	nextPool, q, err := m.pool.ApplySell(side, sharesIn, minCollateralOut)
	if err != nil {
		panic(err.Error())
	}
	nextAcc, err := fpmm.UpdateFeeAccumulator(m.feeAcc, q.Fee, m.pool.TotalLP)
	if err != nil {
		panic(err.Error())
	}
	if q.GrossCollateral > m.collateral || q.GrossCollateral > totalCollateral {
		panic("insufficient market collateral")
	}
	mFee, ok := overflow.Add64(m.feePool, q.Fee)
	if !ok {
		panic("fee pool overflow")
	}
	tFee, ok := overflow.Add64(totalFeePool, q.Fee)
	if !ok {
		panic("total fee pool overflow")
	}
	mVol, ok := overflow.Add64(m.totalVolume, q.GrossCollateral)
	if !ok {
		panic("volume overflow")
	}
	tVol, ok := overflow.Add64(totalVolume, q.GrossCollateral)
	if !ok {
		panic("total volume overflow")
	}

	// Effects before bank interaction.
	if sellYes {
		pos.yesShares -= sharesIn
		m.totalYesOut -= sharesIn
	} else {
		pos.noShares -= sharesIn
		m.totalNoOut -= sharesIn
	}
	pruneEmptyPosition(m, caller, pos)

	m.pool = nextPool
	m.feeAcc = nextAcc
	m.collateral -= q.GrossCollateral
	totalCollateral -= q.GrossCollateral
	m.feePool = mFee
	totalFeePool = tFee
	m.totalVolume = mVol
	totalVolume = tVol
	m.tradeCount++
	totalTrades++

	recordPricePoint(m, now, q.NewYesProbBps, m.totalVolume)

	sendUgnot(0, cur, caller, q.CollateralOut)

	chain.Emit(
		"Trade",
		"marketId", strconv.FormatUint(m.id, 10),
		"trader", caller.String(),
		"action", "sell",
		"side", side.String(),
		"collateral", strconv.FormatInt(q.CollateralOut, 10),
		"shares", strconv.FormatInt(sharesIn, 10),
		"fee", strconv.FormatInt(q.Fee, 10),
		"yesProbBps", strconv.FormatInt(q.NewYesProbBps, 10),
	)
	return q.CollateralOut
}

// AddLiquidity deposits attached ugnot into the pool proportionally and mints LP shares.
// Any excess shares on the scarcer side of a skewed pool are credited to the caller.
// EOA-only (`maketx call`).
func AddLiquidity(cur realm, marketID uint64, minLPMinted int64) int64 {
	deposit := requireEOAPayment(0, cur, 1)
	caller := cur.Previous().Address()
	m := getMarketOrPanic(marketID)

	now := time.Now().Unix()
	if m.status != StatusOpen || now >= m.closeTime {
		panic("market is closed for liquidity")
	}

	nextPool, q, err := m.pool.ApplyAddLiquidity(deposit, minLPMinted)
	if err != nil {
		panic(err.Error())
	}

	mColl, ok := overflow.Add64(m.collateral, deposit)
	if !ok {
		panic("collateral overflow")
	}
	tColl, ok := overflow.Add64(totalCollateral, deposit)
	if !ok {
		panic("total collateral overflow")
	}

	pos := getOrCreatePosition(m, caller)
	earned := fpmm.ComputePendingLPFee(m.feeAcc, pos.lpShares, pos.feeDebt)
	newLP := pos.lpShares + q.LPMinted
	newDebt, err := fpmm.ComputeLPFeeDebt(m.feeAcc, newLP)
	if err != nil {
		panic(err.Error())
	}

	m.pool = nextPool
	m.collateral = mColl
	totalCollateral = tColl

	pos.pendingFees += earned
	pos.lpShares = newLP
	pos.feeDebt = newDebt

	if q.RefundShares > 0 {
		if q.RefundSide == fpmm.SideYes {
			pos.yesShares += q.RefundShares
			m.totalYesOut += q.RefundShares
		} else if q.RefundSide == fpmm.SideNo {
			pos.noShares += q.RefundShares
			m.totalNoOut += q.RefundShares
		}
	}

	chain.Emit(
		"LiquidityAdded",
		"marketId", strconv.FormatUint(m.id, 10),
		"provider", caller.String(),
		"collateral", strconv.FormatInt(deposit, 10),
		"lpMinted", strconv.FormatInt(q.LPMinted, 10),
		"refundShares", strconv.FormatInt(q.RefundShares, 10),
	)
	return q.LPMinted
}

// RemoveLiquidity burns lpShares, merges balanced reserves into ugnot, harvests
// accrued LP fees, and credits any pool skew excess to the caller's share balance.
func RemoveLiquidity(cur realm, marketID uint64, lpShares int64) (collateralOut, feeOut, yesOut, noOut int64) {
	caller := cur.Previous().Address()
	m := getMarketOrPanic(marketID)

	now := time.Now().Unix()
	if m.status != StatusOpen || now >= m.closeTime {
		panic("market is closed for liquidity")
	}
	if lpShares <= 0 {
		panic("lpShares must be positive")
	}

	pos := getPositionOrNil(m, caller)
	if pos == nil || pos.lpShares < lpShares {
		panic("insufficient LP shares")
	}

	nextPool, q, err := m.pool.ApplyRemoveLiquidity(lpShares)
	if err != nil {
		panic(err.Error())
	}
	if q.CollateralOut > m.collateral || q.CollateralOut > totalCollateral {
		panic("insufficient market collateral")
	}

	earned := fpmm.ComputePendingLPFee(m.feeAcc, pos.lpShares, pos.feeDebt)
	feeOut = pos.pendingFees + earned
	if feeOut > m.feePool {
		feeOut = m.feePool
	}
	if feeOut > totalFeePool {
		feeOut = totalFeePool
	}

	newLP := pos.lpShares - lpShares
	newDebt, err := fpmm.ComputeLPFeeDebt(m.feeAcc, newLP)
	if err != nil {
		panic(err.Error())
	}

	// Effects before bank interaction.
	m.pool = nextPool
	m.collateral -= q.CollateralOut
	totalCollateral -= q.CollateralOut
	m.feePool -= feeOut
	totalFeePool -= feeOut

	pos.pendingFees = 0
	pos.lpShares = newLP
	pos.feeDebt = newDebt
	pos.yesShares += q.YesOut
	pos.noShares += q.NoOut
	m.totalYesOut += q.YesOut
	m.totalNoOut += q.NoOut
	pruneEmptyPosition(m, caller, pos)

	sendUgnot(0, cur, caller, q.CollateralOut+feeOut)

	chain.Emit(
		"LiquidityRemoved",
		"marketId", strconv.FormatUint(m.id, 10),
		"provider", caller.String(),
		"lpBurned", strconv.FormatInt(lpShares, 10),
		"collateralOut", strconv.FormatInt(q.CollateralOut, 10),
		"feeOut", strconv.FormatInt(feeOut, 10),
		"yesOut", strconv.FormatInt(q.YesOut, 10),
		"noOut", strconv.FormatInt(q.NoOut, 10),
	)
	return q.CollateralOut, feeOut, q.YesOut, q.NoOut
}

// ProposeOutcome submits an optimistic outcome proposal (1=YES, 2=NO, 3=INVALID)
// after market closeTime with an exact GNOT bond equal to the market's BondAmount.
// EOA-only (`maketx call`).
func ProposeOutcome(cur realm, marketID uint64, outcome uint8) {
	m := getMarketOrPanic(marketID)
	now := time.Now().Unix()
	if m.status != StatusOpen {
		panic("market is not open for proposal")
	}
	if now < m.closeTime {
		panic("market has not closed yet")
	}
	out := Outcome(outcome)
	if !out.ValidResolution() {
		panic("invalid outcome")
	}

	bond := requireExactEOAPayment(0, cur, m.bondAmount)
	caller := cur.Previous().Address()

	nextBonds, ok := overflow.Add64(totalActiveBonds, bond)
	if !ok {
		panic("active bonds overflow")
	}

	m.status = StatusProposed
	m.proposedOutcome = out
	m.proposer = caller
	m.proposedAt = now
	m.disputeDeadline = now + m.disputeWindow
	m.proposerBond = bond
	totalActiveBonds = nextBonds

	chain.Emit(
		"OutcomeProposed",
		"marketId", strconv.FormatUint(m.id, 10),
		"proposer", caller.String(),
		"outcome", out.String(),
		"bond", strconv.FormatInt(bond, 10),
		"disputeDeadline", strconv.FormatInt(m.disputeDeadline, 10),
	)
}

// DisputeOutcome challenges a proposed outcome within its dispute window by
// posting an equal counter-bond and escalating to the arbiter quorum.
// EOA-only (`maketx call`).
func DisputeOutcome(cur realm, marketID uint64) {
	m := getMarketOrPanic(marketID)
	now := time.Now().Unix()
	if m.status != StatusProposed {
		panic("market has no active proposal")
	}
	if now >= m.disputeDeadline {
		panic("dispute window expired")
	}
	caller := cur.Previous().Address()
	if caller == m.proposer {
		panic("proposer cannot self-dispute")
	}

	bond := requireExactEOAPayment(0, cur, m.bondAmount)

	nextBonds, ok := overflow.Add64(totalActiveBonds, bond)
	if !ok {
		panic("active bonds overflow")
	}

	m.status = StatusDisputed
	m.disputer = caller
	m.disputedAt = now
	m.disputerBond = bond
	m.arbiterQuorum = arbiterQuorum
	m.arbiterVotes = avl.NewTree()
	m.yesVotes = 0
	m.noVotes = 0
	m.invalidVotes = 0
	totalActiveBonds = nextBonds

	chain.Emit(
		"OutcomeDisputed",
		"marketId", strconv.FormatUint(m.id, 10),
		"disputer", caller.String(),
		"bond", strconv.FormatInt(bond, 10),
		"quorum", strconv.Itoa(m.arbiterQuorum),
	)
}

// FinalizeResolution permissionlessly finalizes an unchallenged proposal after
// disputeDeadline and credits the proposer's bond to pull-claimable balance.
func FinalizeResolution(cur realm, marketID uint64) {
	m := getMarketOrPanic(marketID)
	now := time.Now().Unix()
	if m.status != StatusProposed {
		panic("market is not proposed")
	}
	if now < m.disputeDeadline {
		panic("dispute window still active")
	}

	bond := m.proposerBond
	m.proposerBond = 0
	totalActiveBonds -= bond
	creditClaimableBond(m.proposer, bond)

	m.status = StatusResolved
	m.finalOutcome = m.proposedOutcome
	m.resolvedAt = now
	snapshotSettlement(m)

	chain.Emit(
		"MarketResolved",
		"marketId", strconv.FormatUint(m.id, 10),
		"outcome", m.finalOutcome.String(),
		"via", "optimistic",
	)
}

// CastArbiterVote records an arbiter's resolution vote on a disputed market.
// Once a single outcome reaches arbiterQuorum votes, the market resolves and
// the dishonest party's bond is awarded to the honest side via ClaimBonds.
func CastArbiterVote(cur realm, marketID uint64, outcome uint8) {
	arb := cur.Previous().Address()
	if !arbiters.Has(arb.String()) {
		panic("caller is not an arbiter")
	}
	m := getMarketOrPanic(marketID)
	if m.status != StatusDisputed {
		panic("market is not disputed")
	}
	out := Outcome(outcome)
	if !out.ValidResolution() {
		panic("invalid outcome")
	}

	votes := m.arbiterVotes
	if votes == nil {
		panic("corrupt arbiter votes tree")
	}
	if votes.Has(arb.String()) {
		panic("arbiter already voted")
	}

	votes.Set(arb.String(), out)
	var count int
	switch out {
	case OutcomeYes:
		m.yesVotes++
		count = m.yesVotes
	case OutcomeNo:
		m.noVotes++
		count = m.noVotes
	case OutcomeInvalid:
		m.invalidVotes++
		count = m.invalidVotes
	}

	chain.Emit(
		"ArbiterVoted",
		"marketId", strconv.FormatUint(m.id, 10),
		"arbiter", arb.String(),
		"outcome", out.String(),
		"tally", strconv.Itoa(count),
		"quorum", strconv.Itoa(m.arbiterQuorum),
	)

	if count < m.arbiterQuorum {
		return
	}

	pot := m.proposerBond + m.disputerBond
	winner := m.disputer
	if out == m.proposedOutcome {
		winner = m.proposer
	}
	m.proposerBond = 0
	m.disputerBond = 0
	totalActiveBonds -= pot
	creditClaimableBond(winner, pot)

	m.status = StatusResolved
	m.finalOutcome = out
	m.resolvedAt = time.Now().Unix()
	snapshotSettlement(m)

	chain.Emit(
		"MarketResolved",
		"marketId", strconv.FormatUint(m.id, 10),
		"outcome", m.finalOutcome.String(),
		"via", "arbiter_quorum",
		"bondWinner", winner.String(),
	)
}

// ExpireDispute is a permissionless liveness escape hatch: if arbiters fail to
// reach quorum within ArbiterTimeout (7 days), anyone can resolve the market
// as INVALID and refund both bonds to claimableBonds.
func ExpireDispute(cur realm, marketID uint64) {
	m := getMarketOrPanic(marketID)
	if m.status != StatusDisputed {
		panic("market is not disputed")
	}
	now := time.Now().Unix()
	if now < m.disputedAt+ArbiterTimeout {
		panic("arbiter timeout not reached")
	}

	pBond := m.proposerBond
	dBond := m.disputerBond
	m.proposerBond = 0
	m.disputerBond = 0
	totalActiveBonds -= (pBond + dBond)
	creditClaimableBond(m.proposer, pBond)
	creditClaimableBond(m.disputer, dBond)

	m.status = StatusResolved
	m.finalOutcome = OutcomeInvalid
	m.resolvedAt = now
	snapshotSettlement(m)

	chain.Emit(
		"MarketResolved",
		"marketId", strconv.FormatUint(m.id, 10),
		"outcome", OutcomeInvalid.String(),
		"via", "arbiter_timeout",
	)
}

// Claim withdraws a participant's resolved winning share payout, LP share
// redemption, and accrued LP fees using pull-only settlement.
func Claim(cur realm, marketID uint64) int64 {
	caller := cur.Previous().Address()
	m := getMarketOrPanic(marketID)
	if m.status != StatusResolved {
		panic("market is not resolved")
	}

	pos := getPositionOrNil(m, caller)
	if pos == nil {
		panic("no position for caller")
	}
	if pos.claimed {
		panic("already claimed")
	}

	sharePayout, feePayout := computePositionClaim(m, pos)
	totalPayout := sharePayout + feePayout
	if totalPayout <= 0 {
		panic("nothing to claim")
	}
	if sharePayout > m.collateral || sharePayout > totalCollateral {
		panic("insufficient market collateral")
	}
	if feePayout > m.feePool || feePayout > totalFeePool {
		panic("insufficient market fee pool")
	}

	claimedLP := pos.lpShares
	claimedYes := pos.yesShares
	claimedNo := pos.noShares

	// CEI: effects before bank transfer.
	pos.claimed = true
	pos.yesShares = 0
	pos.noShares = 0
	pos.lpShares = 0
	pos.feeDebt = 0
	pos.pendingFees = 0

	m.collateral -= sharePayout
	totalCollateral -= sharePayout
	m.feePool -= feePayout
	totalFeePool -= feePayout
	m.remainingLP -= claimedLP

	switch m.finalOutcome {
	case OutcomeYes:
		m.remainingWinShares -= claimedYes
	case OutcomeNo:
		m.remainingWinShares -= claimedNo
	case OutcomeInvalid:
		m.remainingWinShares -= (claimedYes + claimedNo)
	}

	if m.remainingLP == 0 && m.remainingWinShares == 0 {
		if m.collateral > 0 {
			protocolDustPool += m.collateral
			totalCollateral -= m.collateral
			m.collateral = 0
		}
		if m.feePool > 0 {
			protocolDustPool += m.feePool
			totalFeePool -= m.feePool
			m.feePool = 0
		}
	}

	sendUgnot(0, cur, caller, totalPayout)

	chain.Emit(
		"Claimed",
		"marketId", strconv.FormatUint(m.id, 10),
		"claimer", caller.String(),
		"sharePayout", strconv.FormatInt(sharePayout, 10),
		"feePayout", strconv.FormatInt(feePayout, 10),
		"totalPayout", strconv.FormatInt(totalPayout, 10),
	)
	return totalPayout
}

// ClaimBonds pulls all refunded or won dispute bonds owed to the caller.
func ClaimBonds(cur realm) int64 {
	caller := cur.Previous().Address()
	key := caller.String()
	raw := claimableBonds.Get(key)
	if raw == nil {
		panic("no claimable bonds")
	}
	amt, ok := raw.(int64)
	if !ok {
		panic("corrupt claimable bond entry")
	}
	if amt <= 0 {
		panic("no claimable bonds")
	}

	// CEI: remove before bank transfer.
	claimableBonds.Remove(key)
	totalClaimableBonds -= amt

	sendUgnot(0, cur, caller, amt)

	chain.Emit(
		"BondsClaimed",
		"claimer", caller.String(),
		"amount", strconv.FormatInt(amt, 10),
	)
	return amt
}

// WithdrawDust lets admin sweep integer floor-rounding dust left behind after a
// resolved market's final LP and winner claims complete.
func WithdrawDust(cur realm, to address) int64 {
	requireAdmin(0, cur)
	if !to.IsValid() {
		panic("invalid recipient address")
	}
	amt := protocolDustPool
	if amt <= 0 {
		panic("no protocol dust")
	}
	protocolDustPool = 0
	sendUgnot(0, cur, to, amt)
	chain.Emit(
		"DustWithdrawn",
		"to", to.String(),
		"amount", strconv.FormatInt(amt, 10),
	)
	return amt
}

// TransferAdmin rotates the realm admin address.
func TransferAdmin(cur realm, newAdmin address) {
	requireAdmin(0, cur)
	if !newAdmin.IsValid() {
		panic("invalid admin address")
	}
	oldAdmin := admin
	admin = newAdmin
	chain.Emit(
		"AdminTransferred",
		"oldAdmin", oldAdmin.String(),
		"newAdmin", newAdmin.String(),
	)
}

// AddArbiter adds a dispute-resolution arbiter up to MaxArbiters.
func AddArbiter(cur realm, arb address) {
	requireAdmin(0, cur)
	if !arb.IsValid() {
		panic("invalid arbiter address")
	}
	if arbiters.Has(arb.String()) {
		panic("already an arbiter")
	}
	if arbiters.Size() >= MaxArbiters {
		panic("arbiter cap reached")
	}
	arbiters.Set(arb.String(), true)
	chain.Emit("ArbiterAdded", "arbiter", arb.String())
}

// RemoveArbiter removes an arbiter while keeping at least arbiterQuorum active arbiters.
func RemoveArbiter(cur realm, arb address) {
	requireAdmin(0, cur)
	if !arbiters.Has(arb.String()) {
		panic("not an arbiter")
	}
	if arbiters.Size()-1 < arbiterQuorum || arbiters.Size() <= 1 {
		panic("cannot drop arbiters below quorum")
	}
	arbiters.Remove(arb.String())
	chain.Emit("ArbiterRemoved", "arbiter", arb.String())
}

// SetArbiterQuorum sets the required arbiter vote threshold for future disputes.
func SetArbiterQuorum(cur realm, quorum int) {
	requireAdmin(0, cur)
	if quorum < 1 || quorum > arbiters.Size() {
		panic("quorum out of range")
	}
	arbiterQuorum = quorum
	chain.Emit("ArbiterQuorumUpdated", "quorum", strconv.Itoa(quorum))
}

// SetDefaultBond sets the GNOT bond required for new markets within [MinAllowedBond, MaxAllowedBond].
func SetDefaultBond(cur realm, bond int64) {
	requireAdmin(0, cur)
	if bond < MinAllowedBond || bond > MaxAllowedBond {
		panic("bond amount out of bounds")
	}
	defaultBond = bond
	chain.Emit("DefaultBondUpdated", "bond", strconv.FormatInt(bond, 10))
}

func snapshotSettlement(m *market) {
	m.settlementYes = m.pool.ReserveYes
	m.settlementNo = m.pool.ReserveNo
	m.settlementLP = m.pool.TotalLP
	m.remainingLP = m.pool.TotalLP
	resolvedMarketCount++

	switch m.finalOutcome {
	case OutcomeYes:
		m.remainingWinShares = m.totalYesOut
	case OutcomeNo:
		m.remainingWinShares = m.totalNoOut
	case OutcomeInvalid:
		m.remainingWinShares = m.totalYesOut + m.totalNoOut
	}
}

func computePositionClaim(m *market, pos *position) (sharePayout, feePayout int64) {
	var lpYes, lpNo int64
	if pos.lpShares > 0 {
		var err error
		lpYes, lpNo, err = fpmm.QuoteSettleLP(m.settlementYes, m.settlementNo, m.settlementLP, pos.lpShares)
		if err != nil {
			panic(err.Error())
		}
		earned := fpmm.ComputePendingLPFee(m.feeAcc, pos.lpShares, pos.feeDebt)
		feePayout = pos.pendingFees + earned
	} else {
		feePayout = pos.pendingFees
	}
	if feePayout > m.feePool {
		feePayout = m.feePool
	}

	totalYes := pos.yesShares + lpYes
	totalNo := pos.noShares + lpNo

	switch m.finalOutcome {
	case OutcomeYes:
		sharePayout = totalYes
	case OutcomeNo:
		sharePayout = totalNo
	case OutcomeInvalid:
		sharePayout = (totalYes + totalNo) / 2
	default:
		panic("invalid final outcome")
	}
	return sharePayout, feePayout
}
