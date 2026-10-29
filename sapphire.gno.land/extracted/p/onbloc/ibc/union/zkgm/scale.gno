package zkgm

import (
	"errors"
	"math"

	u256 "gno.land/p/onbloc/math/uint256"
)

// ErrAmountOverflow is returned when a (downscaled) amount does not fit int64,
// the width of the grc20/banker ledger.
var ErrAmountOverflow = errors.New("zkgm: amount overflows int64")

// ErrAmountNotDivisible is returned when a source-precision amount carries precision
// below the ledger's canonical scale,
// so dividing by the token's scale factor leaves a remainder.
// It is rejected so cross-chain value is conserved exactly.
var ErrAmountNotDivisible = errors.New("zkgm: amount not divisible by token scale factor")

// ErrPow10Overflow is returned when 10^exp does not fit in a uint256.
var ErrPow10Overflow = errors.New("zkgm: 10^exp overflows uint256")

// Pow10 returns 10^exp as a uint256, rejecting exp too large to fit (>= 78)
// instead of wrapping mod 2^256.
func Pow10(exp int) (*u256.Uint, error) {
	if exp < 0 {
		return u256.Zero(), nil
	}

	result := u256.NewUint(1)
	ten := u256.NewUint(10)

	for i := 0; i < exp; i++ {
		next, overflow := new(u256.Uint).MulOverflow(result, ten)
		if overflow {
			return nil, ErrPow10Overflow
		}

		result = next
	}

	return result, nil
}

// ScaleDownToInt64 narrows an origin-precision amount to an int64 ledger amount
// by dividing by 10^scaleExp.
// scaleExp <= 0 is the identity narrow, used by native and low-decimal tokens.
func ScaleDownToInt64(amount *u256.Uint, scaleExp int) (int64, error) {
	value := amount

	if scaleExp > 0 {
		divisor, err := Pow10(scaleExp)
		if err != nil {
			return 0, err
		}

		quotient, remainder := u256.Zero().DivMod(amount, divisor, u256.Zero())
		if !remainder.IsZero() {
			return 0, ErrAmountNotDivisible
		}

		value = quotient
	}

	valueUint64, overflow := value.Uint64WithOverflow()
	if overflow || valueUint64 > uint64(math.MaxInt64) {
		return 0, ErrAmountOverflow
	}

	return int64(valueUint64), nil
}
