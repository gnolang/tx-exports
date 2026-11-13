package dca

import (
	"strconv"
	"strings"

	"gno.land/p/gnoswap/utils/v1"
)

// MakeGroupID builds the group key
// "inputToken:outputToken:interval:slotOffset".
func MakeGroupID(inputToken string, outputToken string, interval int64, slotOffset int64) string {
	return inputToken + ":" + outputToken + ":" + utils.FormatInt(interval) + ":" + utils.FormatInt(slotOffset)
}

// OrderKey encodes an order ID so B+tree order matches numeric order.
func OrderKey(orderID uint64) string {
	return utils.EncodeUint64(orderID)
}

// RoundKey encodes a round so B+tree order matches numeric order.
func RoundKey(round uint64) string {
	return utils.EncodeUint64(round)
}

// OwnerOrderPrefix is the common prefix of an owner's index keys.
func OwnerOrderPrefix(owner address) string {
	return owner.String() + "/"
}

// OwnerOrderKey sorts an owner's orders by ID under OwnerOrderPrefix.
func OwnerOrderKey(owner address, orderID uint64) string {
	return OwnerOrderPrefix(owner) + utils.EncodeUint64(orderID)
}

// GroupOrderPrefix is the common prefix of a group's order index keys.
// Token paths contain no ':', so one group's prefix never starts another's.
func GroupOrderPrefix(groupID string) string {
	return groupID + "/"
}

// GroupOrderKey sorts a group's orders by ID under GroupOrderPrefix.
func GroupOrderKey(groupID string, orderID uint64) string {
	return GroupOrderPrefix(groupID) + utils.EncodeUint64(orderID)
}

// GroupOrderFeeRatePrefix is the common prefix of the GroupOrderAmountKeys
// of a group's orders with executionFeeRate, under GroupOrderPrefix.
// executionFeeRate is in [0, MaxExecutionFeeRate], so its first byte is 0
// and PrefixEnd of GroupOrderPrefix still bounds every rate's keys.
func GroupOrderFeeRatePrefix(groupID string, executionFeeRate int64) string {
	return GroupOrderPrefix(groupID) + utils.EncodeUint64(uint64(executionFeeRate))
}

// GroupOrderAmountKey sorts a group's orders by executionFeeRate, then
// amountPerExecution, then ID, under GroupOrderFeeRatePrefix.
// amountPerExecution is positive, so its first byte is below 0x80
// and PrefixEnd of GroupOrderFeeRatePrefix still bounds the rate's keys.
func GroupOrderAmountKey(groupID string, executionFeeRate int64, amountPerExecution int64, orderID uint64) string {
	return GroupOrderFeeRatePrefix(groupID, executionFeeRate) + utils.EncodeUint64(uint64(amountPerExecution)) + utils.EncodeUint64(orderID)
}

// GroupOrderAmountKeyFeeRate extracts executionFeeRate from a
// GroupOrderAmountKey of groupID.
func GroupOrderAmountKeyFeeRate(groupID string, key string) int64 {
	start := len(GroupOrderPrefix(groupID))
	return int64(utils.DecodeUint64(key[start : start+8]))
}

// GroupOrderAmountKeyAmount extracts amountPerExecution from a
// GroupOrderAmountKey of groupID.
func GroupOrderAmountKeyAmount(groupID string, key string) int64 {
	start := len(GroupOrderPrefix(groupID)) + 8
	return int64(utils.DecodeUint64(key[start : start+8]))
}

// ExecutionLogPrefix is the common prefix of an order's execution log keys.
func ExecutionLogPrefix(orderID uint64) string {
	return utils.EncodeUint64(orderID)
}

// ExecutionLogKey sorts an order's execution logs by round
// under ExecutionLogPrefix.
func ExecutionLogKey(orderID uint64, round uint64) string {
	return ExecutionLogPrefix(orderID) + utils.EncodeUint64(round)
}

// PrefixEnd is an exclusive upper bound for prefix + 8-byte encoded ID keys.
// Nine 0xff bytes sort after every 8-byte suffix.
func PrefixEnd(prefix string) string {
	return prefix + "\xff\xff\xff\xff\xff\xff\xff\xff\xff"
}

// ScheduleKey orders groups by next execution timestamp, then group ID.
func ScheduleKey(nextExecutionTimestamp int64, groupID string) string {
	return utils.EncodeUint64(uint64(nextExecutionTimestamp)) + groupID
}

// ScheduleKeyTimestamp extracts the next execution timestamp from a ScheduleKey.
func ScheduleKeyTimestamp(key string) int64 {
	return int64(utils.DecodeUint64(key[:8]))
}

// FormatScheduleCursor renders a schedule entry as
// "<nextExecutionTimestamp>|<groupID>".
func FormatScheduleCursor(nextExecutionTimestamp int64, groupID string) string {
	return utils.FormatInt(nextExecutionTimestamp) + "|" + groupID
}

// ParseScheduleCursor converts a "<nextExecutionTimestamp>|<groupID>" cursor
// back to its ScheduleKey.
// An empty cursor yields an empty key, i.e. the start of the index.
// A malformed cursor returns ErrInvalidCursor.
func ParseScheduleCursor(cursor string) (string, error) {
	if cursor == "" {
		return "", nil
	}

	sep := strings.Index(cursor, "|")
	if sep <= 0 {
		return "", ErrInvalidCursor
	}

	nextExecutionTimestamp, err := strconv.ParseInt(cursor[:sep], 10, 64)
	if err != nil || nextExecutionTimestamp < 0 {
		return "", ErrInvalidCursor
	}

	return ScheduleKey(nextExecutionTimestamp, cursor[sep+1:]), nil
}

// PairKey builds the key of a pair direction, "inputToken:outputToken".
// Token paths contain no ':', so the key is unambiguous.
func PairKey(inputToken string, outputToken string) string {
	return inputToken + ":" + outputToken
}
