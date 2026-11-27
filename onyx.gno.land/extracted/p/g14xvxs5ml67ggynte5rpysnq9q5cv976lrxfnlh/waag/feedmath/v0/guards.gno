package feedmath

// This file holds the two predicates that decide whether a price may be
// trusted and published: the deviation guard (ledger O5) and the staleness
// rule (ledger O6). Both are pure - they answer a question and change nothing.

// ---- Deviation guard (ledger O5) -----------------------------------------

// DeviationOK reports whether candidate is close enough to reference to be
// trusted, where closeness is thresholdBps basis points (1 bp = 0.01%, so the
// shipped 10% guard is 1000 bps).
//
// The comparison uses multiplication only, never division:
//
//	|candidate - reference| / reference <= bps / 10000
//	is equivalent to
//	|candidate - reference| * 10000 <= bps * reference
//
// The second form is what we compute. Integer division truncates, so the first
// form would make the guard silently stricter or looser than documented
// depending on the numbers; the multiplied form is exact.
//
// Boundary behaviour: a deviation of EXACTLY the threshold is accepted. The
// guard rejects only strictly greater deviation, matching O5's wording
// ("reject a submission deviating > 10%").
//
// Safety: both products stay inside int64 because ValidPrice bounds prices by
// MaxPrice (MaxPrice * BpsScale is about 1e18, versus an int64 limit near
// 9.22e18) and thresholdBps is capped at MaxThresholdBps.
//
// Panics if either price is invalid or thresholdBps is outside
// [0, MaxThresholdBps] - those are programming errors, not market conditions.
func DeviationOK(candidate, reference Price, thresholdBps int64) bool {
	MustValidPrice(candidate)
	MustValidPrice(reference)
	if thresholdBps < 0 || thresholdBps > MaxThresholdBps {
		panic("feedmath: thresholdBps must be within [0, 10000]")
	}

	diff := int64(AbsDiff(candidate, reference))
	return diff*BpsScale <= thresholdBps*int64(reference)
}

// DeviationBps returns how far candidate sits from reference, in basis points,
// rounded down. It exists so a rejection can be reported in words a human can
// read - "deviated 1340 bps, limit 1000" - instead of just "rejected".
//
// Deliberately separate from DeviationOK: this one divides and therefore
// truncates, which is fine for a message but would be wrong for a decision.
// Deciding and explaining are different jobs, so they are different functions.
func DeviationBps(candidate, reference Price) int64 {
	MustValidPrice(candidate)
	MustValidPrice(reference)

	diff := int64(AbsDiff(candidate, reference))
	return diff * BpsScale / int64(reference)
}

// ---- Staleness (ledger O6) -----------------------------------------------

// IsFresh reports whether a value submitted at submittedHeight still counts as
// current at currentHeight, given a staleness window measured in blocks
// (the shipped default is 300 blocks).
//
// Age is measured in blocks, not wall-clock seconds: a realm cannot read a
// clock on-chain, and block height is the only time the chain itself agrees on.
//
// A submission dated in the future (submittedHeight > currentHeight) is NEVER
// fresh. That cannot happen honestly, so refusing it is free - and it closes a
// real hole: without this check a crafted far-future height would age to
// negative, clamp to zero, and make a source look permanently fresh.
//
// A window of 0 is allowed and means "only the current block counts".
// Panics on a negative window, which is a programming error.
func IsFresh(submittedHeight, currentHeight, window int64) bool {
	if window < 0 {
		panic("feedmath: staleness window cannot be negative")
	}
	if submittedHeight > currentHeight {
		return false
	}
	return currentHeight-submittedHeight <= window
}

// BlockAge returns how many blocks old a submission is, clamped to 0 when the
// submission is dated at or after currentHeight.
//
// This is a DISPLAY helper for the dashboard, which wants to print an age
// rather than a verdict - and printing "0 blocks" for an impossible
// future-dated row is harmless. It is deliberately NOT the trust decision:
// IsFresh is the authority on whether a source counts, and it rejects
// future-dated heights outright.
func BlockAge(submittedHeight, currentHeight int64) int64 {
	age := currentHeight - submittedHeight
	if age < 0 {
		return 0
	}
	return age
}
