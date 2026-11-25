// Package streammath provides pure, overflow-safe, zero-dust linear vesting
// and payment-stream calculations for Gno.land realms.
package streammath

import (
	"errors"
	"math/bits"
	"strconv"
	"strings"
)

const (
	// UGNOTPerGNOT is the number of micro-GNOT (ugnot) in 1 GNOT.
	UGNOTPerGNOT = 1_000_000
	// MaxBps represents 100.00% in basis points.
	MaxBps = 10_000
)

var (
	ErrInvalidTotalAmount = errors.New("streammath: total amount must be positive")
	ErrInvalidStartHeight = errors.New("streammath: start height must be non-negative")
	ErrInvalidEndHeight   = errors.New("streammath: end height must be greater than start height")
	ErrInvalidCliffHeight = errors.New("streammath: cliff height must be between start height and end height")
)

// ValidateSchedule checks whether a vesting schedule is well-formed.
// Valid schedules satisfy:
//   - totalAmount > 0
//   - 0 <= startHeight < endHeight
//   - startHeight <= cliffHeight <= endHeight
func ValidateSchedule(startHeight, cliffHeight, endHeight, totalAmount int64) error {
	if totalAmount <= 0 {
		return ErrInvalidTotalAmount
	}
	if startHeight < 0 {
		return ErrInvalidStartHeight
	}
	if endHeight <= startHeight {
		return ErrInvalidEndHeight
	}
	if cliffHeight < startHeight || cliffHeight > endHeight {
		return ErrInvalidCliffHeight
	}
	return nil
}

// VestedAmount computes the cumulative vested amount at currentHeight using
// exact 128-bit integer arithmetic (no int64 overflow, no floating-point drift).
//
// Rules:
//   - Invalid schedule -> 0
//   - currentHeight < cliffHeight -> 0
//   - currentHeight >= endHeight -> totalAmount
//   - cliffHeight <= currentHeight < endHeight ->
//     floor(totalAmount * (currentHeight - startHeight) / (endHeight - startHeight))
func VestedAmount(totalAmount, startHeight, cliffHeight, endHeight, currentHeight int64) int64 {
	if ValidateSchedule(startHeight, cliffHeight, endHeight, totalAmount) != nil {
		return 0
	}
	if currentHeight < cliffHeight {
		return 0
	}
	if currentHeight >= endHeight {
		return totalAmount
	}
	if currentHeight <= startHeight {
		return 0
	}

	elapsed := uint64(currentHeight - startHeight)
	duration := uint64(endHeight - startHeight)
	hi, lo := bits.Mul64(uint64(totalAmount), elapsed)
	quo, _ := bits.Div64(hi, lo, duration)
	return int64(quo)
}

// WithdrawableAmount returns the currently claimable amount for a recipient
// given the amount already withdrawn.
func WithdrawableAmount(totalAmount, withdrawn, startHeight, cliffHeight, endHeight, currentHeight int64) int64 {
	if withdrawn < 0 {
		withdrawn = 0
	}
	vested := VestedAmount(totalAmount, startHeight, cliffHeight, endHeight, currentHeight)
	if vested <= withdrawn {
		return 0
	}
	return vested - withdrawn
}

// CancelSplit computes the exact settlement amounts when a stream is cancelled
// at currentHeight. It strictly satisfies the zero-dust conservation invariant:
//
//	withdrawn + toRecipient + toSender == totalAmount
//
// whenever 0 <= withdrawn <= totalAmount and totalAmount > 0.
func CancelSplit(totalAmount, withdrawn, startHeight, cliffHeight, endHeight, currentHeight int64) (toRecipient int64, toSender int64) {
	if totalAmount <= 0 {
		return 0, 0
	}
	if withdrawn < 0 {
		withdrawn = 0
	}
	if withdrawn >= totalAmount {
		return 0, 0
	}

	remaining := totalAmount - withdrawn
	toRecipient = WithdrawableAmount(totalAmount, withdrawn, startHeight, cliffHeight, endHeight, currentHeight)
	if toRecipient > remaining {
		toRecipient = remaining
	}
	toSender = remaining - toRecipient
	return toRecipient, toSender
}

// ProgressBps returns elapsed stream progress in basis points (0..10000),
// computed with exact 128-bit integer arithmetic.
func ProgressBps(startHeight, endHeight, currentHeight int64) int64 {
	if startHeight < 0 || endHeight <= startHeight || currentHeight <= startHeight {
		return 0
	}
	if currentHeight >= endHeight {
		return MaxBps
	}

	elapsed := uint64(currentHeight - startHeight)
	duration := uint64(endHeight - startHeight)
	hi, lo := bits.Mul64(MaxBps, elapsed)
	quo, _ := bits.Div64(hi, lo, duration)
	return int64(quo)
}

// ProgressBar renders a Unicode block progress bar with percentage,
// e.g. ProgressBar(8000, 10) -> "████████░░ 80.0%".
func ProgressBar(bps int64, width int) string {
	if bps < 0 {
		bps = 0
	}
	if bps > MaxBps {
		bps = MaxBps
	}
	if width <= 0 {
		width = 10
	}

	filled := int((bps * int64(width)) / MaxBps)
	if filled > width {
		filled = width
	}

	wholePct := bps / 100
	tenthsPct := (bps % 100) / 10

	var b strings.Builder
	for i := 0; i < filled; i++ {
		b.WriteString("█")
	}
	for i := filled; i < width; i++ {
		b.WriteString("░")
	}
	b.WriteString(" ")
	b.WriteString(strconv.FormatInt(wholePct, 10))
	b.WriteString(".")
	b.WriteString(strconv.FormatInt(tenthsPct, 10))
	b.WriteString("%")
	return b.String()
}

// FormatUGNOT formats an amount in ugnot as human-readable GNOT with 6 decimal
// places, e.g. FormatUGNOT(12500000) -> "12.500000 GNOT".
func FormatUGNOT(ugnot int64) string {
	negative := ugnot < 0
	var abs uint64
	if negative {
		// Safe even for math.MinInt64.
		abs = uint64(-(ugnot + 1)) + 1
	} else {
		abs = uint64(ugnot)
	}

	whole := abs / UGNOTPerGNOT
	frac := abs % UGNOTPerGNOT

	fracStr := strconv.FormatUint(frac, 10)
	if len(fracStr) < 6 {
		fracStr = strings.Repeat("0", 6-len(fracStr)) + fracStr
	}

	var b strings.Builder
	if negative {
		b.WriteString("-")
	}
	b.WriteString(strconv.FormatUint(whole, 10))
	b.WriteString(".")
	b.WriteString(fracStr)
	b.WriteString(" GNOT")
	return b.String()
}
