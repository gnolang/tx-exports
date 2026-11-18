package dca

import (
	"errors"
)

var (
	// ErrInvalidInput is returned when an argument is out of its domain.
	ErrInvalidInput = errors.New("invalid input")

	// ErrOverflow is returned when a result does not fit in int64.
	ErrOverflow = errors.New("int64 overflow")

	// ErrAccumulatorBackwards is returned when the payout accumulator
	// is below the order's debt.
	ErrAccumulatorBackwards = errors.New("accumulator moved backwards")

	// ErrInvalidCursor is returned when a schedule cursor cannot be parsed.
	ErrInvalidCursor = errors.New("invalid cursor")

	// ErrIntervalExists is returned when adding an interval already allowed.
	ErrIntervalExists = errors.New("interval already allowed")

	// ErrIntervalNotFound is returned when removing an interval not allowed.
	ErrIntervalNotFound = errors.New("interval not allowed")
)
