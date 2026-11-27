package fpmm

import (
	"errors"
	"math/overflow"
)

const (
	// BpsScale is 100.00% expressed in basis points.
	BpsScale int64 = 10_000

	// MaxFeeBps caps swap fees at 10.00% (1,000 bps).
	MaxFeeBps int64 = 1_000

	// MinReserve is the minimum reserve per outcome side after pool init
	// or liquidity removal so odds never collapse into degenerate dust.
	MinReserve int64 = 100

	// MaxReserve caps individual reserves and inputs at 10^15 ugnot
	// (1 billion GNOT), preventing intermediate arithmetic overflow.
	MaxReserve int64 = 1_000_000_000_000_000

	// FeeAccScale scales per-LP-share fee accruals by 10^12 for sub-ugnot precision.
	FeeAccScale uint64 = 1_000_000_000_000

	maxInt64 = int64(1<<63 - 1)
)

// Side identifies an outcome share in a binary market.
type Side uint8

const (
	SideYes Side = 1
	SideNo  Side = 2
)

// Valid reports whether s is SideYes or SideNo.
func (s Side) Valid() bool {
	return s == SideYes || s == SideNo
}

// String returns the human-readable outcome label.
func (s Side) String() string {
	switch s {
	case SideYes:
		return "YES"
	case SideNo:
		return "NO"
	default:
		return "UNKNOWN"
	}
}

var (
	ErrInvalidReserve        = errors.New("fpmm: invalid reserve")
	ErrInvalidAmount         = errors.New("fpmm: invalid amount")
	ErrInvalidFeeBps         = errors.New("fpmm: invalid fee bps")
	ErrInvalidSide           = errors.New("fpmm: invalid side")
	ErrZeroOutput            = errors.New("fpmm: output is zero")
	ErrSlippage              = errors.New("fpmm: slippage limit exceeded")
	ErrOverflow              = errors.New("fpmm: arithmetic overflow")
	ErrInsufficientLiquidity = errors.New("fpmm: insufficient liquidity")
)

// Pool holds the constant-product state for a binary prediction market.
type Pool struct {
	ReserveYes int64
	ReserveNo  int64
	TotalLP    int64
	FeeBps     int64
}

// BuyQuote describes the state transition for buying outcome shares.
type BuyQuote struct {
	SharesOut     int64
	Fee           int64
	NetCollateral int64
	NewReserveYes int64
	NewReserveNo  int64
	NewYesProbBps int64
}

// SellQuote describes the state transition for selling outcome shares.
type SellQuote struct {
	CollateralOut   int64
	Fee             int64
	GrossCollateral int64
	NewReserveYes   int64
	NewReserveNo    int64
	NewYesProbBps   int64
}

// AddLiquidityQuote describes a proportional liquidity deposit.
// For skewed pools, excess shares on the scarcer side are returned as RefundShares.
type AddLiquidityQuote struct {
	LPMinted      int64
	AddedYes      int64
	AddedNo       int64
	RefundSide    Side
	RefundShares  int64
	NewReserveYes int64
	NewReserveNo  int64
}

// RemoveLiquidityQuote describes a proportional liquidity withdrawal.
// Equal YES/NO reserves are merged into CollateralOut; excess skew is returned as shares.
type RemoveLiquidityQuote struct {
	CollateralOut int64
	YesOut        int64
	NoOut         int64
	NewReserveYes int64
	NewReserveNo  int64
}

// FeeAccumulator stores a 128-bit magnified fee-per-LP-share accumulator.
type FeeAccumulator struct {
	AccHi uint64
	AccLo uint64
}

// NewPool initializes a balanced 50/50 binary CPMM pool backed by initialCollateral.
func NewPool(initialCollateral, feeBps int64) (Pool, error) {
	if initialCollateral < MinReserve || initialCollateral > MaxReserve {
		return Pool{}, ErrInvalidReserve
	}
	if feeBps < 0 || feeBps > MaxFeeBps {
		return Pool{}, ErrInvalidFeeBps
	}
	return Pool{
		ReserveYes: initialCollateral,
		ReserveNo:  initialCollateral,
		TotalLP:    initialCollateral,
		FeeBps:     feeBps,
	}, nil
}

// Validate checks that pool reserves, LP supply, and fee parameters are well-formed.
func (p Pool) Validate() error {
	if p.ReserveYes < 1 || p.ReserveYes > MaxReserve {
		return ErrInvalidReserve
	}
	if p.ReserveNo < 1 || p.ReserveNo > MaxReserve {
		return ErrInvalidReserve
	}
	if p.TotalLP < 1 || p.TotalLP > MaxReserve {
		return ErrInsufficientLiquidity
	}
	if p.FeeBps < 0 || p.FeeBps > MaxFeeBps {
		return ErrInvalidFeeBps
	}
	return nil
}

// YesProbBps returns the implied YES probability in [0, 10000] basis points.
func (p Pool) YesProbBps() int64 {
	if p.ReserveYes <= 0 || p.ReserveNo <= 0 {
		return 0
	}
	sum := uint64(p.ReserveYes) + uint64(p.ReserveNo)
	prob, ok := mulDivFloor(uint64(p.ReserveNo), uint64(BpsScale), sum)
	if !ok {
		return 0
	}
	return int64(prob)
}

// NoProbBps returns the implied NO probability in [0, 10000] basis points.
func (p Pool) NoProbBps() int64 {
	if p.ReserveYes <= 0 || p.ReserveNo <= 0 {
		return 0
	}
	return BpsScale - p.YesProbBps()
}

// InvariantHiLo returns the exact 128-bit product ReserveYes * ReserveNo.
func (p Pool) InvariantHiLo() (hi, lo uint64) {
	if p.ReserveYes <= 0 || p.ReserveNo <= 0 {
		return 0, 0
	}
	k := u128Mul64(uint64(p.ReserveYes), uint64(p.ReserveNo))
	return k.hi, k.lo
}

// QuoteBuy calculates the exact outcome shares received for grossCollateral ugnot.
func (p Pool) QuoteBuy(side Side, grossCollateral int64) (BuyQuote, error) {
	if err := p.Validate(); err != nil {
		return BuyQuote{}, err
	}
	if !side.Valid() {
		return BuyQuote{}, ErrInvalidSide
	}
	if grossCollateral <= 0 || grossCollateral > MaxReserve {
		return BuyQuote{}, ErrInvalidAmount
	}

	var fee int64
	if p.FeeBps > 0 {
		f, ok := mulDivCeil(uint64(grossCollateral), uint64(p.FeeBps), uint64(BpsScale))
		if !ok || f > uint64(maxInt64) {
			return BuyQuote{}, ErrOverflow
		}
		fee = int64(f)
	}
	net := grossCollateral - fee
	if net <= 0 {
		return BuyQuote{}, ErrZeroOutput
	}

	rTarget, rOther := p.ReserveYes, p.ReserveNo
	if side == SideNo {
		rTarget, rOther = p.ReserveNo, p.ReserveYes
	}

	newOther, ok := overflow.Add64(rOther, net)
	if !ok || newOther > MaxReserve {
		return BuyQuote{}, ErrOverflow
	}
	poolPlusNet, ok := overflow.Add64(rTarget, net)
	if !ok {
		return BuyQuote{}, ErrOverflow
	}

	newTargetU64, ok := mulDivCeil(uint64(rTarget), uint64(rOther), uint64(newOther))
	if !ok || newTargetU64 > uint64(MaxReserve) {
		return BuyQuote{}, ErrOverflow
	}
	newTarget := int64(newTargetU64)
	if newTarget < 1 {
		newTarget = 1
	}
	if newTarget >= poolPlusNet {
		return BuyQuote{}, ErrZeroOutput
	}
	sharesOut := poolPlusNet - newTarget

	newYes, newNo := newTarget, newOther
	if side == SideNo {
		newYes, newNo = newOther, newTarget
	}

	nextPool := Pool{
		ReserveYes: newYes,
		ReserveNo:  newNo,
		TotalLP:    p.TotalLP,
		FeeBps:     p.FeeBps,
	}

	return BuyQuote{
		SharesOut:     sharesOut,
		Fee:           fee,
		NetCollateral: net,
		NewReserveYes: newYes,
		NewReserveNo:  newNo,
		NewYesProbBps: nextPool.YesProbBps(),
	}, nil
}

// ApplyBuy executes a buy quote against slippage protection minSharesOut.
func (p Pool) ApplyBuy(side Side, grossCollateral, minSharesOut int64) (Pool, BuyQuote, error) {
	if minSharesOut < 0 {
		return Pool{}, BuyQuote{}, ErrInvalidAmount
	}
	q, err := p.QuoteBuy(side, grossCollateral)
	if err != nil {
		return Pool{}, BuyQuote{}, err
	}
	if q.SharesOut < minSharesOut {
		return Pool{}, BuyQuote{}, ErrSlippage
	}
	next := Pool{
		ReserveYes: q.NewReserveYes,
		ReserveNo:  q.NewReserveNo,
		TotalLP:    p.TotalLP,
		FeeBps:     p.FeeBps,
	}
	return next, q, nil
}

// QuoteSell calculates exact net collateral returned when selling sharesIn back to the pool.
func (p Pool) QuoteSell(side Side, sharesIn int64) (SellQuote, error) {
	if err := p.Validate(); err != nil {
		return SellQuote{}, err
	}
	if !side.Valid() {
		return SellQuote{}, ErrInvalidSide
	}
	if sharesIn <= 0 || sharesIn > MaxReserve {
		return SellQuote{}, ErrInvalidAmount
	}

	rTarget, rOther := p.ReserveYes, p.ReserveNo
	if side == SideNo {
		rTarget, rOther = p.ReserveNo, p.ReserveYes
	}

	lhs, ok := overflow.Add64(rTarget, sharesIn)
	if !ok || lhs > MaxReserve {
		return SellQuote{}, ErrOverflow
	}

	// Solve c^2 - B*c + rOther*sharesIn >= 0 with B = rTarget + rOther + sharesIn.
	// Discriminant: B^2 - 4*rOther*sharesIn = (lhs - rOther)^2 + 4*rTarget*rOther.
	bCoeff := uint64(lhs) + uint64(rOther)
	var absDiff uint64
	if lhs >= rOther {
		absDiff = uint64(lhs - rOther)
	} else {
		absDiff = uint64(rOther - lhs)
	}

	term1 := u128Mul64(absDiff, absDiff)
	k := u128Mul64(uint64(rTarget), uint64(rOther))
	twoK, ok := u128Add(k, k)
	if !ok {
		return SellQuote{}, ErrOverflow
	}
	fourK, ok := u128Add(twoK, twoK)
	if !ok {
		return SellQuote{}, ErrOverflow
	}
	disc, ok := u128Add(term1, fourK)
	if !ok {
		return SellQuote{}, ErrOverflow
	}

	// Ceiling sqrt guarantees grossCollateral rounds down so k' >= k holds strictly.
	sqrtCeil, ok := u128SqrtCeil(disc)
	if !ok {
		return SellQuote{}, ErrOverflow
	}
	if sqrtCeil >= bCoeff {
		return SellQuote{}, ErrZeroOutput
	}
	grossU64 := (bCoeff - sqrtCeil) / 2
	if grossU64 == 0 {
		return SellQuote{}, ErrZeroOutput
	}
	if grossU64 > uint64(maxInt64) {
		return SellQuote{}, ErrOverflow
	}
	gross := int64(grossU64)

	newTarget := lhs - gross
	newOther := rOther - gross
	if newTarget < 1 || newOther < 1 {
		return SellQuote{}, ErrZeroOutput
	}
	if newTarget > MaxReserve {
		return SellQuote{}, ErrOverflow
	}

	var fee int64
	if p.FeeBps > 0 {
		f, ok := mulDivCeil(uint64(gross), uint64(p.FeeBps), uint64(BpsScale))
		if !ok || f > uint64(maxInt64) {
			return SellQuote{}, ErrOverflow
		}
		fee = int64(f)
	}
	netOut := gross - fee
	if netOut <= 0 {
		return SellQuote{}, ErrZeroOutput
	}

	newYes, newNo := newTarget, newOther
	if side == SideNo {
		newYes, newNo = newOther, newTarget
	}

	nextPool := Pool{
		ReserveYes: newYes,
		ReserveNo:  newNo,
		TotalLP:    p.TotalLP,
		FeeBps:     p.FeeBps,
	}

	return SellQuote{
		CollateralOut:   netOut,
		Fee:             fee,
		GrossCollateral: gross,
		NewReserveYes:   newYes,
		NewReserveNo:    newNo,
		NewYesProbBps:   nextPool.YesProbBps(),
	}, nil
}

// ApplySell executes a sell quote against slippage protection minCollateralOut.
func (p Pool) ApplySell(side Side, sharesIn, minCollateralOut int64) (Pool, SellQuote, error) {
	if minCollateralOut < 0 {
		return Pool{}, SellQuote{}, ErrInvalidAmount
	}
	q, err := p.QuoteSell(side, sharesIn)
	if err != nil {
		return Pool{}, SellQuote{}, err
	}
	if q.CollateralOut < minCollateralOut {
		return Pool{}, SellQuote{}, ErrSlippage
	}
	next := Pool{
		ReserveYes: q.NewReserveYes,
		ReserveNo:  q.NewReserveNo,
		TotalLP:    p.TotalLP,
		FeeBps:     p.FeeBps,
	}
	return next, q, nil
}

// QuoteAddLiquidity calculates LP shares minted and excess skew shares returned
// when depositing collateralIn ugnot proportionally to current reserves.
func (p Pool) QuoteAddLiquidity(collateralIn int64) (AddLiquidityQuote, error) {
	if err := p.Validate(); err != nil {
		return AddLiquidityQuote{}, err
	}
	if collateralIn <= 0 || collateralIn > MaxReserve {
		return AddLiquidityQuote{}, ErrInvalidAmount
	}

	var (
		addedYes     int64
		addedNo      int64
		refundSide   Side
		refundShares int64
		lpMintedU64  uint64
		ok           bool
	)

	if p.ReserveYes >= p.ReserveNo {
		addedYes = collateralIn
		addedNoU64, mulOk := mulDivFloor(uint64(collateralIn), uint64(p.ReserveNo), uint64(p.ReserveYes))
		if !mulOk || addedNoU64 > uint64(MaxReserve) {
			return AddLiquidityQuote{}, ErrOverflow
		}
		addedNo = int64(addedNoU64)
		refundShares = collateralIn - addedNo
		if refundShares > 0 {
			refundSide = SideNo
		}
		lpMintedU64, ok = mulDivFloor(uint64(addedNo), uint64(p.TotalLP), uint64(p.ReserveNo))
	} else {
		addedNo = collateralIn
		addedYesU64, mulOk := mulDivFloor(uint64(collateralIn), uint64(p.ReserveYes), uint64(p.ReserveNo))
		if !mulOk || addedYesU64 > uint64(MaxReserve) {
			return AddLiquidityQuote{}, ErrOverflow
		}
		addedYes = int64(addedYesU64)
		refundShares = collateralIn - addedYes
		if refundShares > 0 {
			refundSide = SideYes
		}
		lpMintedU64, ok = mulDivFloor(uint64(addedYes), uint64(p.TotalLP), uint64(p.ReserveYes))
	}

	if !ok || lpMintedU64 > uint64(MaxReserve) {
		return AddLiquidityQuote{}, ErrOverflow
	}
	lpMinted := int64(lpMintedU64)
	if lpMinted <= 0 {
		return AddLiquidityQuote{}, ErrZeroOutput
	}

	newYes, ok := overflow.Add64(p.ReserveYes, addedYes)
	if !ok || newYes > MaxReserve {
		return AddLiquidityQuote{}, ErrOverflow
	}
	newNo, ok := overflow.Add64(p.ReserveNo, addedNo)
	if !ok || newNo > MaxReserve {
		return AddLiquidityQuote{}, ErrOverflow
	}
	newTotalLP, ok := overflow.Add64(p.TotalLP, lpMinted)
	if !ok || newTotalLP > MaxReserve {
		return AddLiquidityQuote{}, ErrOverflow
	}

	return AddLiquidityQuote{
		LPMinted:      lpMinted,
		AddedYes:      addedYes,
		AddedNo:       addedNo,
		RefundSide:    refundSide,
		RefundShares:  refundShares,
		NewReserveYes: newYes,
		NewReserveNo:  newNo,
	}, nil
}

// ApplyAddLiquidity executes a liquidity deposit against slippage protection minLPMinted.
func (p Pool) ApplyAddLiquidity(collateralIn, minLPMinted int64) (Pool, AddLiquidityQuote, error) {
	if minLPMinted < 0 {
		return Pool{}, AddLiquidityQuote{}, ErrInvalidAmount
	}
	q, err := p.QuoteAddLiquidity(collateralIn)
	if err != nil {
		return Pool{}, AddLiquidityQuote{}, err
	}
	if q.LPMinted < minLPMinted {
		return Pool{}, AddLiquidityQuote{}, ErrSlippage
	}
	next := Pool{
		ReserveYes: q.NewReserveYes,
		ReserveNo:  q.NewReserveNo,
		TotalLP:    p.TotalLP + q.LPMinted,
		FeeBps:     p.FeeBps,
	}
	return next, q, nil
}

// QuoteRemoveLiquidity calculates merged collateral and excess shares withdrawn
// for burning lpBurn LP shares while keeping at least MinReserve on both sides.
func (p Pool) QuoteRemoveLiquidity(lpBurn int64) (RemoveLiquidityQuote, error) {
	if err := p.Validate(); err != nil {
		return RemoveLiquidityQuote{}, err
	}
	if lpBurn <= 0 || lpBurn > MaxReserve {
		return RemoveLiquidityQuote{}, ErrInvalidAmount
	}
	if lpBurn >= p.TotalLP {
		return RemoveLiquidityQuote{}, ErrInsufficientLiquidity
	}

	rawYesU64, ok := mulDivFloor(uint64(p.ReserveYes), uint64(lpBurn), uint64(p.TotalLP))
	if !ok {
		return RemoveLiquidityQuote{}, ErrOverflow
	}
	rawNoU64, ok := mulDivFloor(uint64(p.ReserveNo), uint64(lpBurn), uint64(p.TotalLP))
	if !ok {
		return RemoveLiquidityQuote{}, ErrOverflow
	}
	rawYes := int64(rawYesU64)
	rawNo := int64(rawNoU64)

	newYes := p.ReserveYes - rawYes
	newNo := p.ReserveNo - rawNo
	if newYes < MinReserve || newNo < MinReserve {
		return RemoveLiquidityQuote{}, ErrInsufficientLiquidity
	}

	merged := rawYes
	if rawNo < merged {
		merged = rawNo
	}
	yesOut := rawYes - merged
	noOut := rawNo - merged
	if merged == 0 && yesOut == 0 && noOut == 0 {
		return RemoveLiquidityQuote{}, ErrZeroOutput
	}

	return RemoveLiquidityQuote{
		CollateralOut: merged,
		YesOut:        yesOut,
		NoOut:         noOut,
		NewReserveYes: newYes,
		NewReserveNo:  newNo,
	}, nil
}

// ApplyRemoveLiquidity executes a proportional liquidity withdrawal.
func (p Pool) ApplyRemoveLiquidity(lpBurn int64) (Pool, RemoveLiquidityQuote, error) {
	q, err := p.QuoteRemoveLiquidity(lpBurn)
	if err != nil {
		return Pool{}, RemoveLiquidityQuote{}, err
	}
	next := Pool{
		ReserveYes: q.NewReserveYes,
		ReserveNo:  q.NewReserveNo,
		TotalLP:    p.TotalLP - lpBurn,
		FeeBps:     p.FeeBps,
	}
	return next, q, nil
}

// QuoteSettleLP computes floor-rounded pro-rata YES and NO reserves due to an LP
// upon market resolution so the sum across all LPs never exceeds settlement reserves.
func QuoteSettleLP(settlementYes, settlementNo, settlementLP, lpShares int64) (yesOut, noOut int64, err error) {
	if settlementLP <= 0 || settlementYes < 0 || settlementNo < 0 {
		return 0, 0, ErrInvalidReserve
	}
	if lpShares <= 0 || lpShares > settlementLP {
		return 0, 0, ErrInvalidAmount
	}
	yU64, ok := mulDivFloor(uint64(settlementYes), uint64(lpShares), uint64(settlementLP))
	if !ok || yU64 > uint64(maxInt64) {
		return 0, 0, ErrOverflow
	}
	nU64, ok := mulDivFloor(uint64(settlementNo), uint64(lpShares), uint64(settlementLP))
	if !ok || nU64 > uint64(maxInt64) {
		return 0, 0, ErrOverflow
	}
	return int64(yU64), int64(nU64), nil
}

// UpdateFeeAccumulator adds fee / totalLP (scaled by FeeAccScale, floored) to acc.
func UpdateFeeAccumulator(acc FeeAccumulator, fee, totalLP int64) (FeeAccumulator, error) {
	if fee < 0 {
		return FeeAccumulator{}, ErrInvalidAmount
	}
	if totalLP <= 0 {
		return FeeAccumulator{}, ErrInsufficientLiquidity
	}
	if fee == 0 {
		return acc, nil
	}
	delta, _ := u128Div64(u128Mul64(uint64(fee), FeeAccScale), uint64(totalLP))
	next, ok := u128Add(u128{hi: acc.AccHi, lo: acc.AccLo}, delta)
	if !ok {
		return FeeAccumulator{}, ErrOverflow
	}
	return FeeAccumulator{AccHi: next.hi, AccLo: next.lo}, nil
}

// ComputeLPFeeDebt calculates ceil(acc * lpShares / FeeAccScale) so newly
// minted LP shares cannot claim fees earned prior to their deposit.
func ComputeLPFeeDebt(acc FeeAccumulator, lpShares int64) (int64, error) {
	if lpShares < 0 {
		return 0, ErrInvalidAmount
	}
	if lpShares == 0 {
		return 0, nil
	}
	debt, ok := mulAccDiv(u128{hi: acc.AccHi, lo: acc.AccLo}, uint64(lpShares), FeeAccScale, true)
	if !ok {
		return 0, ErrOverflow
	}
	return debt, nil
}

// ComputePendingLPFee calculates floor(acc * lpShares / FeeAccScale) - feeDebt.
func ComputePendingLPFee(acc FeeAccumulator, lpShares, feeDebt int64) int64 {
	if lpShares <= 0 {
		return 0
	}
	entitled, ok := mulAccDiv(u128{hi: acc.AccHi, lo: acc.AccLo}, uint64(lpShares), FeeAccScale, false)
	if !ok || entitled <= feeDebt {
		return 0
	}
	return entitled - feeDebt
}
