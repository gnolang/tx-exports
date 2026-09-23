// Package book is the integer accounting for a Charter round.
// It does not move coins. Amounts are ugnot or token base units.
// Products that do not fit in int64 panic. A denominator above
// MaxDen panics so the limb division cannot overflow.
package book

import "math"

const (
	// Bps is one hundred percent.
	Bps int64 = 10000
	// MaxPot is the largest ugnot total a round may hold (1e16).
	// It stays under MaxInt64/256 so mulDivFloor can divide byte by byte.
	MaxPot int64 = 10000000000000000
)

// maxDen is the largest safe divisor for mulDivFloor.
const maxDen = math.MaxInt64 / 256

// MulDivFloor returns floor(a*b/den) for non-negative inputs.
// It panics if den is outside (0, maxDen] or the quotient does not fit in int64.
func MulDivFloor(a, b, den int64) int64 {
	if a < 0 || b < 0 || den <= 0 || den > maxDen {
		panic("muldiv")
	}
	if a == 0 || b == 0 {
		return 0
	}
	var p [16]int64
	for i := 0; i < 8; i++ {
		ai := (a >> (uint(i) * 8)) & 0xFF
		if ai == 0 {
			continue
		}
		for j := 0; j < 8; j++ {
			bj := (b >> (uint(j) * 8)) & 0xFF
			p[i+j] += ai * bj
		}
	}
	for i := 0; i < 15; i++ {
		p[i+1] += p[i] >> 8
		p[i] &= 0xFF
	}
	if p[15] > 0xFF {
		panic("muldiv")
	}
	var rem int64
	var result int64
	for i := 15; i >= 0; i-- {
		rem = rem*256 + p[i]
		digit := rem / den
		rem = rem % den
		if i >= 8 {
			if digit != 0 {
				panic("muldiv overflow")
			}
			continue
		}
		result = result*256 + digit
	}
	return result
}

// Accepted splits one contribution when the round is oversubscribed.
// When total <= hard the whole payment is accepted.
func Accepted(paid, hard, total int64) (accepted, excess int64) {
	if paid < 0 || hard <= 0 || total <= 0 || paid > total || hard > MaxPot || total > MaxPot {
		panic("bad accept")
	}
	if total <= hard {
		return paid, 0
	}
	accepted = MulDivFloor(paid, hard, total)
	excess = paid - accepted
	return accepted, excess
}

// BondShare is this contribution's pull of the bond after a failed round.
func BondShare(bond, paid, total int64) int64 {
	if bond < 0 || paid < 0 || total <= 0 || paid > total || bond > MaxPot || total > MaxPot {
		panic("bad bond share")
	}
	return MulDivFloor(bond, paid, total)
}

// ContributorUnits is accepted ugnot divided by the frozen price.
func ContributorUnits(accepted, price int64) int64 {
	if accepted < 0 || price <= 0 || accepted > MaxPot || price > MaxPot {
		panic("bad units")
	}
	return accepted / price
}

// TeamUnits is the team slice implied by contributor units and team bps.
// teamBps is a share of the total supply, so the team receives
// contributorUnits * teamBps / (Bps - teamBps).
func TeamUnits(contributorUnits, teamBps int64) int64 {
	if contributorUnits < 0 || teamBps < 0 || teamBps >= Bps {
		panic("bad team")
	}
	if contributorUnits == 0 || teamBps == 0 {
		return 0
	}
	return MulDivFloor(contributorUnits, teamBps, Bps-teamBps)
}

// Accrued is the ugnot unlocked by a constant tap from mark until now, capped.
func Accrued(accrued, tap, mark, now, cap int64) int64 {
	if accrued < 0 || tap < 0 || cap < 0 || now < mark || accrued > cap {
		panic("bad accrue")
	}
	if tap == 0 || accrued == cap || now == mark {
		return accrued
	}
	dt := now - mark
	room := cap - accrued
	if dt > room/tap {
		return cap
	}
	return accrued + tap*dt
}

// Budget is the unlocked ugnot at now, including a tap raise that has come due.
// The higher tap accrues only after pendingAt. It is not applied back to t0.
func Budget(accrued, tap, mark, now, cap, pendingTap, pendingAt int64) int64 {
	if pendingTap < 0 || pendingAt < 0 {
		panic("bad budget")
	}
	if pendingTap > 0 && now >= pendingAt {
		accrued = Accrued(accrued, tap, mark, pendingAt, cap)
		tap = pendingTap
		mark = pendingAt
	}
	return Accrued(accrued, tap, mark, now, cap)
}

// AccountLocked is the part of one contribution the contributor can still exit.
func AccountLocked(accepted, budget, original int64) int64 {
	if accepted < 0 || budget < 0 || original <= 0 || budget > original || accepted > original {
		panic("bad locked")
	}
	unlocked := MulDivFloor(accepted, budget, original)
	if unlocked > accepted {
		panic("bad locked")
	}
	return accepted - unlocked
}

// Vested is the linear team entitlement. elapsed >= duration vests the total.
func Vested(total, elapsed, duration int64) int64 {
	if total < 0 || elapsed < 0 || duration <= 0 {
		panic("bad vest")
	}
	if elapsed >= duration {
		return total
	}
	return MulDivFloor(total, elapsed, duration)
}
