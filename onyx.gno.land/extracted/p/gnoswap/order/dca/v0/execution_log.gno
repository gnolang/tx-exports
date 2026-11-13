package dca

import (
	"gno.land/p/gnoswap/gnsmath/v1"
	bptree "gno.land/p/nt/bptree/v0"

	"gno.land/p/gnoswap/utils/v1"
)

// ExecutionLogRoundCount is the number of consecutive rounds of an order
// one execution log covers. A tree entry costs about 640 bytes of storage
// whatever it holds, so covering three rounds keeps the deposit near
// 0.02 GNOT per round at 100 ugnot per byte.
const ExecutionLogRoundCount uint64 = 3

// ExecutionLog is an order's record of up to ExecutionLogRoundCount
// consecutive rounds, [firstRound, lastRound], and the input the order sells
// in each. The rounds' swap results are in the DCAGroupExecuted events,
// and accounting uses the group accumulator.
//
// AllocateExecutionLogs stores an order's logs in the realm's executionLogs
// tree, keyed by ExecutionLogKey(orderID, firstRound), so the order owner
// pays their storage deposit up front; ExecuteGroup writes none. Once every
// round of a log executed, anyone may release it through Claim or
// ClaimGroupOrders, and a finished order releases all of its logs; the freed
// deposit is refunded to the transaction signer.
//
// The tree stores only lastRound, a primitive kept inside the B+tree leaf;
// firstRound comes from the key and amountIn from the order.
type ExecutionLog struct {
	firstRound uint64
	lastRound  uint64
	amountIn   int64 // input the order sells in each round, its amountPerExecution
}

func (l *ExecutionLog) FirstRound() uint64 { return l.firstRound }
func (l *ExecutionLog) LastRound() uint64  { return l.lastRound }
func (l *ExecutionLog) AmountIn() int64    { return l.amountIn }

// RoundCount returns the number of rounds the log covers.
func (l *ExecutionLog) RoundCount() uint64 { return l.lastRound - l.firstRound + 1 }

// AllocateExecutionLogs stores the logs of the order's unreleased rounds,
// ExecutionLogRoundCount rounds per log, and returns how many were stored.
func AllocateExecutionLogs(executionLogs *bptree.BPTree, order *Order) int64 {
	allocatedCount := int64(0)

	for firstRound := gnsmath.SafeAddUint64(order.releasedRound, 1); firstRound <= order.endRound; {
		lastRound := lastRoundOfLog(firstRound, order.endRound)
		executionLogs.Set(ExecutionLogKey(order.id, firstRound), lastRound)

		allocatedCount++

		if lastRound == order.endRound {
			break
		}

		firstRound = gnsmath.SafeAddUint64(lastRound, 1)
	}

	return allocatedCount
}

// ReleaseExecutionLogs removes the order's logs whose rounds all executed by
// executedRound, the group round, and returns how many were released.
// A log with a round still to run stays.
func ReleaseExecutionLogs(executionLogs *bptree.BPTree, order *Order, executedRound uint64) int64 {
	if executedRound > order.endRound {
		executedRound = order.endRound
	}

	releasedCount := int64(0)

	for order.releasedRound < order.endRound {
		firstRound := gnsmath.SafeAddUint64(order.releasedRound, 1)

		lastRound := lastRoundOfLog(firstRound, order.endRound)
		if lastRound > executedRound {
			break
		}

		executionLogs.Remove(ExecutionLogKey(order.id, firstRound))
		order.setReleasedRound(lastRound)

		releasedCount++
	}

	return releasedCount
}

// ReleaseAllExecutionLogs removes every log of the order, executed or not,
// and returns how many were released.
func ReleaseAllExecutionLogs(executionLogs *bptree.BPTree, order *Order) int64 {
	return ReleaseExecutionLogs(executionLogs, order, order.endRound)
}

// ExecutionLogs returns up to count of the order's unreleased logs,
// oldest first.
func ExecutionLogs(executionLogs *bptree.BPTree, order *Order, count int) []*ExecutionLog {
	logs := []*ExecutionLog{}
	if count <= 0 {
		return logs
	}

	prefix := ExecutionLogPrefix(order.id)
	executionLogs.Iterate(prefix, PrefixEnd(prefix), func(key string, value any) bool {
		logs = append(logs, &ExecutionLog{
			firstRound: utils.DecodeUint64(key[len(prefix):]),
			lastRound:  value.(uint64),
			amountIn:   order.amountPerExecution,
		})

		return len(logs) >= count
	})

	return logs
}

// lastRoundOfLog returns the last round of the log starting at firstRound.
func lastRoundOfLog(firstRound uint64, endRound uint64) uint64 {
	if endRound-firstRound < ExecutionLogRoundCount {
		return endRound
	}

	return gnsmath.SafeAddUint64(firstRound, ExecutionLogRoundCount-1)
}
