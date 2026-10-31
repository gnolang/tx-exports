package safe

import (
	"strconv"
	"strings"

	"gno.land/p/g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069/sinopia/types/v1"
)

// BpsDenominator is 100% in basis points (EIP-2981, royalty/v0).
const BpsDenominator = 10000

// BpsOf returns floor(amount * bps / 10000) without ever forming the full
// product, so it cannot overflow for any amount >= 0 and 0 <= bps <= 10000.
func BpsOf(amount, bps int64) int64 {
	if amount < 0 {
		panic("BpsOf: negative amount")
	}
	if bps < 0 || bps > BpsDenominator {
		panic("BpsOf: bps out of range")
	}
	return (amount/BpsDenominator)*bps + (amount%BpsDenominator)*bps/BpsDenominator
}

// AssertBps panics unless 0 <= bps <= cap.
func AssertBps(field string, bps, cap int64) {
	if bps < 0 || bps > cap {
		panic(field + ": must be between 0 and " + strconv.FormatInt(cap, 10) + " bps")
	}
}

// ParsePayees parses "g1…:7000,g1…:3000": 1..max distinct valid addresses,
// each with a positive share, shares summing to exactly 10000.
func ParsePayees(field, s string, max int) []types.Payee {
	if s == "" {
		panic(field + ": must not be empty")
	}
	parts := strings.Split(s, ",")
	if len(parts) > max {
		panic(field + ": at most " + strconv.Itoa(max) + " payees")
	}
	out := make([]types.Payee, 0, len(parts))
	var total int64
	for _, part := range parts {
		addrStr, bpsStr, ok := strings.Cut(part, ":")
		if !ok {
			panic(field + ": expected address:bps, got " + strconv.Quote(part))
		}
		addr := address(addrStr)
		if !addr.IsValid() {
			panic(field + ": invalid address " + strconv.Quote(addrStr))
		}
		bps, err := strconv.ParseInt(bpsStr, 10, 64)
		if err != nil || bps <= 0 || bps > BpsDenominator {
			panic(field + ": invalid share " + strconv.Quote(bpsStr))
		}
		for _, p := range out {
			if p.Addr == addr {
				panic(field + ": duplicate payee " + addrStr)
			}
		}
		total += bps
		out = append(out, types.Payee{Addr: addr, Bps: bps})
	}
	if total != BpsDenominator {
		panic(field + ": shares must sum to 10000 bps, got " + strconv.FormatInt(total, 10))
	}
	return out
}

// FormatPayees is the inverse of ParsePayees.
func FormatPayees(ps []types.Payee) string {
	parts := make([]string, len(ps))
	for i, p := range ps {
		parts[i] = p.Addr.String() + ":" + strconv.FormatInt(p.Bps, 10)
	}
	return strings.Join(parts, ",")
}

// SplitByBps divides amount by the payees' shares. The rounding remainder
// goes to the first payee, so the parts always sum to exactly amount — the
// property every "no balance left behind" invariant (I-3, I-4) relies on.
func SplitByBps(amount int64, ps []types.Payee) []int64 {
	if len(ps) == 0 {
		panic("SplitByBps: no payees")
	}
	out := make([]int64, len(ps))
	var given int64
	for i, p := range ps {
		out[i] = BpsOf(amount, p.Bps)
		given += out[i]
	}
	out[0] += amount - given
	return out
}
