package zkgm

import (
	"errors"

	u256 "gno.land/p/onbloc/math/uint256"
)

// ErrChannelPathFull is returned by UpdateChannelPath when the path can no
// longer hold another hop.
var ErrChannelPathFull = errors.New("zkgm: channel path is full")

// ErrNonCanonicalPath is returned when a channel path has a zero-value slot
// below HopCount(path).
var ErrNonCanonicalPath = errors.New("zkgm: channel path is not canonical")

const (
	channelIDMask  = uint64(0xFFFFFFFF)
	channelSlotBit = uint(32)
	maxHopIndex    = 7
	// MaxHops is the largest number of channel hops a path can encode.
	// Mirrors the maxHopIndex+1 invariant enforced by UpdateChannelPath.
	MaxHops = maxHopIndex + 1
)

func channelIDMaskU256() *u256.Uint { return u256.NewUint(channelIDMask) }

// DequeueChannelFromPath pops the lowest 32-bit channel slot off the path and
// shifts the remainder right. Returns the truncated path and the popped
// channel ID. A channel ID of 0 means the path was empty.
//
// Based on Union's `dequeue_channel_from_path` path helper.
func DequeueChannelFromPath(path *u256.Uint) (*u256.Uint, uint32) {
	if path.IsZero() {
		return u256.Zero(), 0
	}

	newPath := u256.Zero().Rsh(path, channelSlotBit)
	low := u256.Zero().And(path, channelIDMaskU256())

	return newPath, uint32(low.Uint64())
}

// PopChannelFromPath extracts the highest non-zero 32-bit channel slot from
// the path, returning the path with that slot cleared and the popped channel
// ID. A channel ID of 0 means the path was empty.
//
// Based on Union's `pop_channel_from_path` path helper.
func PopChannelFromPath(path *u256.Uint) (*u256.Uint, uint32) {
	if path.IsZero() {
		return u256.Zero(), 0
	}

	highestIndex := uint(path.BitLen()-1) / channelSlotBit
	channelID := GetChannelFromPath(path, int(highestIndex))

	slotMask := u256.Zero().Lsh(channelIDMaskU256(), highestIndex*channelSlotBit)
	basePath := u256.Zero().AndNot(path, slotMask)

	return basePath, channelID
}

// UpdateChannelPath appends nextChannelID to the path at the next free
// 32-bit slot. Returns ErrChannelPathFull when the path can no longer hold
// another hop.
//
// Uses the occupied slot count so full-width 32-bit channel IDs still append
// to the immediately next slot instead of skipping an aligned bit boundary.
func UpdateChannelPath(path *u256.Uint, nextChannelID uint32) (*u256.Uint, error) {
	if path.IsZero() {
		return u256.NewUint(uint64(nextChannelID)), nil
	}

	nextHopIndex := HopCount(path)
	if nextHopIndex > maxHopIndex {
		return nil, ErrChannelPathFull
	}

	slot := MakePathFromChannel(nextChannelID, nextHopIndex)

	return u256.Zero().Or(slot, path), nil
}

// GetChannelFromPath returns the channel ID stored at the given 32-bit slot
// (0-indexed from the LSB). Returns 0 if the slot is empty or out of range.
//
// Based on Union's `get_channel_from_path` path helper.
func GetChannelFromPath(path *u256.Uint, index int) uint32 {
	if index < 0 {
		return 0
	}

	shifted := u256.Zero().Rsh(path, uint(index)*channelSlotBit)
	masked := u256.Zero().And(shifted, channelIDMaskU256())

	return uint32(masked.Uint64())
}

// HopCount returns the number of 32-bit channel slots occupied by path.
// A nil or zero path has zero hops.
func HopCount(path *u256.Uint) int {
	if path == nil || path.IsZero() {
		return 0
	}

	return (path.BitLen() + int(channelSlotBit) - 1) / int(channelSlotBit)
}

// IsCanonicalPath reports whether all occupied channel slots are contiguous.
func IsCanonicalPath(path *u256.Uint) bool {
	hops := HopCount(path)
	for i := 0; i < hops; i++ {
		if GetChannelFromPath(path, i) == 0 {
			return false
		}
	}

	return true
}

// MakePathFromChannel builds a path containing channelID at the given slot.
//
// Based on Union's `make_path_from_channel` path helper.
func MakePathFromChannel(channelID uint32, index int) *u256.Uint {
	if index < 0 {
		return u256.Zero()
	}

	return u256.Zero().Lsh(u256.NewUint(uint64(channelID)), uint(index)*channelSlotBit)
}

// ReverseChannelPath returns a path with the same channel hops in reversed
// order. Returns ErrNonCanonicalPath if path has a gap below its occupied
// slots, or ErrChannelPathFull when the reversed path would overflow.
//
// Callers already pass canonical paths; the check guards future callers.
//
// Based on Union's `reverse_channel_path` path helper.
func ReverseChannelPath(path *u256.Uint) (*u256.Uint, error) {
	if !IsCanonicalPath(path) {
		return nil, ErrNonCanonicalPath
	}

	reversed := u256.Zero()

	cur := path
	for hops := 0; hops < MaxHops; hops++ {
		tail, head := PopChannelFromPath(cur)
		if head != 0 {
			updated, err := UpdateChannelPath(reversed, head)
			if err != nil {
				return nil, err
			}

			reversed = updated
		}

		if tail.IsZero() {
			return reversed, nil
		}

		cur = tail
	}
	// A valid uint256 path has at most MaxHops 32-bit slots. Reaching this
	// branch means the path invariant was violated before the tail was consumed.
	return nil, ErrChannelPathFull
}
