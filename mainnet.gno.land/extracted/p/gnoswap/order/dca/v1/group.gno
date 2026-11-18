package dca

import (
	u256 "gno.land/p/gnoswap/uint256/v1"
	rotree "gno.land/p/nt/bptree/rotree/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

// roundMarkBPTreeFanout is the fanout of a group's round mark B+tree.
const roundMarkBPTreeFanout = 16

// Group aggregates the orders selling inputToken for outputToken
// at the same interval and slot offset.
// Its rounds run at the unix times t with t % interval == slotOffset.
// A round sells the sum of their amountPerExecution (orderAmount)
// in one pool swap, on the pool chosen at execution time,
// and adds the gross output per unit of input to
// accumulatedOutputPerAmountX128; each order's execution fee is deducted
// when the order is paid out.
type Group struct {
	id          string
	inputToken  string
	outputToken string
	interval    int64
	slotOffset  int64 // seconds after each interval boundary of the unix epoch

	round                          uint64     // number of executed rounds
	orderAmount                    int64      // input sold in the next round, sum of active amountPerExecution
	accumulatedOutputPerAmountX128 *u256.Uint // cumulative output per unit of input, Q128
	nextExecutionTimestamp         int64      // earliest unix time of the next execution

	activeOrderCount int64 // number of unfinalized orders

	roundMarks *bptree.BPTree // EncodeUint64(round) -> *RoundMark
}

// NewGroup creates an empty group whose first round is due at nextExecutionTimestamp.
func NewGroup(id string, inputToken string, outputToken string, interval int64, slotOffset int64, nextExecutionTimestamp int64) *Group {
	return &Group{
		id:                             id,
		inputToken:                     inputToken,
		outputToken:                    outputToken,
		interval:                       interval,
		slotOffset:                     slotOffset,
		round:                          0,
		orderAmount:                    0,
		accumulatedOutputPerAmountX128: u256.Zero(),
		nextExecutionTimestamp:         nextExecutionTimestamp,
		activeOrderCount:               0,
		roundMarks:                     bptree.NewBPTreeN(roundMarkBPTreeFanout),
	}
}

// Clone returns a deep copy of the group, including its round marks,
// so callers can read it without aliasing stored state.
// Its cost grows with the number of round marks; getters use
// CloneWithoutRoundMarks instead.
func (g *Group) Clone() *Group {
	clone := g.CloneWithoutRoundMarks()
	g.roundMarks.Iterate("", "", func(key string, value any) bool {
		clone.roundMarks.Set(key, value.(*RoundMark).Clone())
		return false
	})

	return clone
}

// CloneWithoutRoundMarks returns a copy of the group's fields with an empty
// round mark tree, at a cost independent of the number of round marks.
// Like Clone, it shares no state with g; read the marks through RoundMarks.
func (g *Group) CloneWithoutRoundMarks() *Group {
	return &Group{
		id:                             g.id,
		inputToken:                     g.inputToken,
		outputToken:                    g.outputToken,
		interval:                       g.interval,
		slotOffset:                     g.slotOffset,
		round:                          g.round,
		orderAmount:                    g.orderAmount,
		accumulatedOutputPerAmountX128: g.accumulatedOutputPerAmountX128.Clone(),
		nextExecutionTimestamp:         g.nextExecutionTimestamp,
		activeOrderCount:               g.activeOrderCount,
		roundMarks:                     bptree.NewBPTreeN(roundMarkBPTreeFanout),
	}
}

func (g *Group) ID() string          { return g.id }
func (g *Group) InputToken() string  { return g.inputToken }
func (g *Group) OutputToken() string { return g.outputToken }
func (g *Group) Interval() int64     { return g.interval }
func (g *Group) SlotOffset() int64   { return g.slotOffset }

func (g *Group) Round() uint64     { return g.round }
func (g *Group) SetRound(v uint64) { g.round = v }

func (g *Group) OrderAmount() int64     { return g.orderAmount }
func (g *Group) SetOrderAmount(v int64) { g.orderAmount = v }

func (g *Group) AccumulatedOutputPerAmountX128() *u256.Uint {
	return g.accumulatedOutputPerAmountX128.Clone()
}
func (g *Group) SetAccumulatedOutputPerAmountX128(v *u256.Uint) {
	g.accumulatedOutputPerAmountX128.Set(v)
}

func (g *Group) NextExecutionTimestamp() int64     { return g.nextExecutionTimestamp }
func (g *Group) SetNextExecutionTimestamp(v int64) { g.nextExecutionTimestamp = v }

func (g *Group) ActiveOrderCount() int64     { return g.activeOrderCount }
func (g *Group) SetActiveOrderCount(v int64) { g.activeOrderCount = v }

func (g *Group) RoundMarkCount() int { return g.roundMarks.Size() }

// GetRoundMark returns the mark of a round, or nil when no order ends there.
func (g *Group) GetRoundMark(round uint64) *RoundMark {
	value := g.roundMarks.Get(RoundKey(round))
	if value == nil {
		return nil
	}

	return value.(*RoundMark)
}

// RoundMarks returns a read-only view of the round marks keyed by RoundKey.
// Each mark read from the view is a copy, so the view cannot reach stored state.
func (g *Group) RoundMarks() *rotree.ReadOnlyTree {
	return rotree.Wrap(g.roundMarks, cloneRoundMarkEntry)
}

// GetOrCreateRoundMark returns the mark of a round, creating it if missing.
func (g *Group) GetOrCreateRoundMark(round uint64) *RoundMark {
	mark := g.GetRoundMark(round)
	if mark != nil {
		return mark
	}

	// Allocate the snapshot slot now, while creating the first order
	// ending here, so that order's creator pays its storage deposit
	// instead of the keeper who later executes the round.
	mark = &RoundMark{orderAmount: 0, orderCount: 0, accumulatedOutputPerAmountX128: u256.Zero()}
	g.roundMarks.Set(RoundKey(round), mark)

	return mark
}

func (g *Group) RemoveRoundMark(round uint64) {
	g.roundMarks.Remove(RoundKey(round))
}

// RoundMark tracks the orders whose last round is the mark's round.
//
// When the round executes, orderAmount leaves the group orderAmount,
// and accumulatedOutputPerAmountX128 snapshots the group accumulator,
// so finished orders are paid without per-round history.
// The mark is removed once orderCount, the number of unfinalized orders
// ending at the round, reaches zero.
type RoundMark struct {
	orderAmount                    int64      // sum of amountPerExecution of the orders ending at the round
	orderCount                     int64      // number of unfinalized orders ending at the round
	accumulatedOutputPerAmountX128 *u256.Uint // valid once the group round reaches the mark
}

// Clone returns a deep copy of the mark.
func (m *RoundMark) Clone() *RoundMark {
	return &RoundMark{
		orderAmount:                    m.orderAmount,
		orderCount:                     m.orderCount,
		accumulatedOutputPerAmountX128: m.accumulatedOutputPerAmountX128.Clone(),
	}
}

func cloneRoundMarkEntry(value any) any {
	mark, ok := value.(*RoundMark)
	if !ok {
		return nil
	}

	return mark.Clone()
}

func (m *RoundMark) OrderAmount() int64     { return m.orderAmount }
func (m *RoundMark) SetOrderAmount(v int64) { m.orderAmount = v }

func (m *RoundMark) OrderCount() int64     { return m.orderCount }
func (m *RoundMark) SetOrderCount(v int64) { m.orderCount = v }

func (m *RoundMark) AccumulatedOutputPerAmountX128() *u256.Uint {
	return m.accumulatedOutputPerAmountX128.Clone()
}

// SnapshotAccumulatedOutputPerAmountX128 records the group accumulator
// right after the round executes.
// It writes into the existing slot, so no new object is stored.
func (m *RoundMark) SnapshotAccumulatedOutputPerAmountX128(v *u256.Uint) {
	m.accumulatedOutputPerAmountX128.Set(v)
}
