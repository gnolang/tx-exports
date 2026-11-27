package bs_core

import (
	"errors"
	"math/overflow"
)

// SafeAdd64 adds two int64 values and saturates at MaxInt64 on overflow.
// Used by non-panicking accounting/reputation counters.
func SafeAdd64(a, b int64) int64 {
	if b > 0 && a > (1<<63-1)-b {
		return 1<<63 - 1
	}
	if b < 0 && a < (-1<<63)-b {
		return -1 << 63
	}
	return a + b
}

// StrictAdd64 returns an error on int64 overflow/underflow.
func StrictAdd64(a, b int64) (int64, error) {
	sum, ok := overflow.Add64(a, b)
	if !ok {
		return 0, errors.New("int64 overflow")
	}
	return sum, nil
}

// CalcProtocolFee computes the 2% floor protocol fee on a positive payout.
func CalcProtocolFee(amount int64) int64 {
	if amount <= 0 {
		return 0
	}
	return (amount * ProtocolFeePct) / 100
}

// CalcDisputeFee computes the 5% floor dispute fee on a quest/slot reward.
func CalcDisputeFee(reward int64) int64 {
	if reward <= 0 {
		return 0
	}
	return (reward * DisputeFeePct) / 100
}

// StakeBounds returns the inclusive [minStake, maxStake] bounds (5%..15% of reward).
func StakeBounds(reward int64) (minStake, maxStake int64) {
	if reward <= 0 {
		return 0, 0
	}
	return (reward * MinStakePct) / 100, (reward * MaxStakePct) / 100
}

// ValidateReward checks reward >= MinRewardUgnot and prevents multiplication overflow.
func ValidateReward(reward int64) error {
	if reward < MinRewardUgnot {
		return errors.New("reward below minimum (1 GNOT / 1000000ugnot)")
	}
	// Ensure reward * 100 stays safely within int64.
	if reward > (1<<63-1)/100 {
		return errors.New("reward exceeds safe integer bound")
	}
	return nil
}

// ValidateStakeBounds enforces stake in [5%, 15%] of reward (no absolute floor).
func ValidateStakeBounds(reward, stake int64) error {
	if err := ValidateReward(reward); err != nil {
		return err
	}
	minStake, maxStake := StakeBounds(reward)
	if stake <= 0 || stake < minStake || stake > maxStake {
		return errors.New("stake must be between 5% and 15% of reward")
	}
	return nil
}

// CalcArbiterTimeoutSplit computes the exact 50/50 split on arbiter timeout
// under the global rounding rule:
//   - half = reward / 2
//   - sponsorAmt = half
//   - fee = floor(half * 2 / 100)
//   - builderNet = half - fee
//   - remainder = reward - 2*half (0 or 1 ugnot)
//   - treasuryAmt = fee + remainder
// Invariant: sponsorAmt + builderNet + treasuryAmt == reward.
func CalcArbiterTimeoutSplit(reward int64) (sponsorAmt, builderNet, treasuryAmt int64) {
	if reward <= 0 {
		return 0, 0, 0
	}
	half := reward / 2
	fee := CalcProtocolFee(half)
	rem := reward - (2 * half)
	return half, half - fee, fee + rem
}

// ValidateContestShares ensures 1..MaxContestSlots shares, each >= MinContestSlotPct,
// summing to exactly 100.
func ValidateContestShares(pcts []int) error {
	if len(pcts) < 1 || len(pcts) > MaxContestSlots {
		return errors.New("contest winner slots must be between 1 and 10")
	}
	sum := 0
	for _, p := range pcts {
		if p < MinContestSlotPct || p > 100 {
			return errors.New("each contest winner share must be between 5% and 100%")
		}
		sum += p
	}
	if sum != 100 {
		return errors.New("contest winner shares must sum to 100%")
	}
	return nil
}

// CalcContestPayouts computes exact payouts for an Open Contest with filledCount winners
// (1 <= filledCount <= len(pcts)).
//   - Filled slot i < filledCount: gross = (R * pcts[i]) / 100, fee = (gross * 2) / 100, net = gross - fee.
//   - Unfilled slot j >= filledCount: refunded to sponsor without fee: (R * pcts[j]) / 100.
//   - Remainder: R - sum_all((R * pcts[i]) / 100) -> Treasury.
// Invariant: sum(winnerNets) + sponsorRefund + treasuryTotal == reward.
func CalcContestPayouts(reward int64, pcts []int, filledCount int) (winnerNets []int64, sponsorRefund int64, treasuryTotal int64, err error) {
	if err = ValidateReward(reward); err != nil {
		return nil, 0, 0, err
	}
	if err = ValidateContestShares(pcts); err != nil {
		return nil, 0, 0, err
	}
	if filledCount < 1 || filledCount > len(pcts) {
		return nil, 0, 0, errors.New("invalid filled winner count")
	}

	winnerNets = make([]int64, filledCount)
	var allocatedGross int64
	var totalFees int64

	for i, pct := range pcts {
		gross := (reward * int64(pct)) / 100
		allocatedGross += gross
		if i < filledCount {
			fee := CalcProtocolFee(gross)
			winnerNets[i] = gross - fee
			totalFees += fee
		} else {
			sponsorRefund += gross
		}
	}

	remainder := reward - allocatedGross
	treasuryTotal = totalFees + remainder
	return winnerNets, sponsorRefund, treasuryTotal, nil
}

// CalcContestEqualSplit computes the Pull-Payment equal split when both sponsor
// and arbiter time out on an Open Contest with submitterCount > 0.
//   - fee = (R * 2) / 100
//   - dist = R - fee
//   - perSubmitter = dist / submitterCount
//   - heldEscrow = perSubmitter * submitterCount
//   - remainder = dist - heldEscrow
//   - treasuryTotal = fee + remainder
// Invariant: heldEscrow + treasuryTotal == reward.
func CalcContestEqualSplit(reward int64, submitterCount int) (perSubmitter, heldEscrow, treasuryTotal int64, err error) {
	if err = ValidateReward(reward); err != nil {
		return 0, 0, 0, err
	}
	if submitterCount <= 0 || submitterCount > MaxContestSubmissions {
		return 0, 0, 0, errors.New("invalid submitter count")
	}
	fee := CalcProtocolFee(reward)
	dist := reward - fee
	n := int64(submitterCount)
	perSubmitter = dist / n
	heldEscrow = perSubmitter * n
	rem := dist - heldEscrow
	treasuryTotal = fee + rem
	return perSubmitter, heldEscrow, treasuryTotal, nil
}

// ValidateQuestDurations validates open, work, and review durations against contract bounds.
func ValidateQuestDurations(openDur, workDur, reviewDur int64) error {
	if openDur < MinOpenDurationSec || openDur > MaxOpenDurationSec {
		return errors.New("open duration must be between 24h and 90d")
	}
	if workDur < MinWorkDurationSec || workDur > MaxWorkDurationSec {
		return errors.New("work duration must be between 24h and 30d")
	}
	if reviewDur < MinReviewDurationSec || reviewDur > MaxReviewDurationSec {
		return errors.New("review duration must be between 24h and 7d")
	}
	return nil
}

// ValidateContestDurations validates submit (open) and judging durations.
func ValidateContestDurations(submitDur, judgingDur int64) error {
	if submitDur < MinOpenDurationSec || submitDur > MaxOpenDurationSec {
		return errors.New("submit duration must be between 24h and 90d")
	}
	if judgingDur < MinJudgingDurationSec || judgingDur > MaxJudgingDurationSec {
		return errors.New("judging duration must be between 24h and 14d")
	}
	return nil
}

// ClampPageLimit normalizes pagination parameters to safe bounds.
func ClampPageLimit(page, limit int) (int, int) {
	if page < 1 {
		page = 1
	}
	if limit <= 0 {
		limit = DefaultPageLimit
	}
	if limit > MaxPageLimit {
		limit = MaxPageLimit
	}
	return page, limit
}
