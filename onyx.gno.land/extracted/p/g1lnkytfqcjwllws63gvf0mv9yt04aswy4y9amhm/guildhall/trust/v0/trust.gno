// Package trust implements the scoring rules behind Guildhall reputation.
//
// Reputation is earned one record at a time. When a piece of work is paid
// out, the realm that recorded it asks this package how many points the work
// is worth. The answer depends on who vouched for it: every approving
// reviewer contributes their current trust, and the record is worth
// Base points scaled by the average trust of its reviewers.
//
// Trust is expressed in basis points (0..10000):
//
//   - seed reviewers (chosen by the realm that uses this package) always carry full trust;
//   - everyone else carries trust proportional to their own score, reaching
//     full trust at TrustThreshold and never exceeding it;
//   - a reviewer who is also the worker carries no trust at all.
//
// With the default TrustFloorBps of 0, work vouched for only by strangers is
// still recorded but earns nothing. This is what makes the score resistant to
// sybils: a ring of fresh addresses reviewing each other stays at zero until
// someone already trusted vouches for one of them. Trust flows outward from
// the seeds, EigenTrust-style, one paid record at a time.
//
// Scores are computed incrementally at record time, never retroactively, so
// every point on a profile can be traced to one record and the trust its
// reviewers held when they approved it.
package trust

import (
	"errors"
)

// MaxBps is the basis-point denominator used for trust and shares.
const MaxBps int64 = 10000

// Params tunes the scoring rules.
type Params struct {
	// Base is the number of points a record earns when every reviewer
	// carries full trust and the worker received the full payout.
	Base int64
	// TrustThreshold is the score at which a non-seed reviewer reaches
	// full trust.
	TrustThreshold int64
	// TrustFloorBps is the minimum trust any eligible reviewer carries.
	TrustFloorBps int64
	// SelfFundedFactorBps scales the points of work funded by the worker
	// themselves. Zero means self-funded work earns nothing.
	SelfFundedFactorBps int64
}

// DefaultParams returns the parameters Guildhall launches with.
func DefaultParams() Params {
	return Params{
		Base:                100,
		TrustThreshold:      500,
		TrustFloorBps:       0,
		SelfFundedFactorBps: 0,
	}
}

// Validate reports whether the parameters are usable.
func (p Params) Validate() error {
	if p.Base <= 0 {
		return errors.New("trust: base must be positive")
	}
	if p.TrustThreshold <= 0 {
		return errors.New("trust: threshold must be positive")
	}
	if p.TrustFloorBps < 0 || p.TrustFloorBps > MaxBps {
		return errors.New("trust: floor must be within 0..10000 bps")
	}
	if p.SelfFundedFactorBps < 0 || p.SelfFundedFactorBps > MaxBps {
		return errors.New("trust: self-funded factor must be within 0..10000 bps")
	}
	return nil
}

// Reviewer describes a reviewer at the moment they vouched for a record.
type Reviewer struct {
	Addr  address
	Score int64
	Seed  bool
}

// Input describes a paid piece of work.
type Input struct {
	Worker    address
	Poster    address
	Reviewers []Reviewer
	// ShareBps is the fraction of the milestone paid to the worker, in basis
	// points. Approved milestones pay 10000; arbitrated disputes may pay
	// less.
	ShareBps int64
}

// Result is the scoring outcome for one record.
type Result struct {
	// Points awarded to the worker.
	Points int64
	// TrustBps holds each reviewer's trust, index-aligned with
	// Input.Reviewers.
	TrustBps []int64
	// AvgTrustBps is the mean trust across reviewers.
	AvgTrustBps int64
}

// TrustOf returns the trust, in basis points, carried by a reviewer.
func TrustOf(r Reviewer, worker address, p Params) int64 {
	if r.Addr == worker {
		return 0
	}
	if r.Seed {
		return MaxBps
	}
	t := int64(0)
	if r.Score > 0 {
		if r.Score >= p.TrustThreshold {
			t = MaxBps
		} else {
			t = r.Score * MaxBps / p.TrustThreshold
		}
	}
	if t < p.TrustFloorBps {
		t = p.TrustFloorBps
	}
	return t
}

// Evaluate scores a paid piece of work.
func Evaluate(in Input, p Params) (Result, error) {
	if err := p.Validate(); err != nil {
		return Result{}, err
	}
	if in.ShareBps < 0 || in.ShareBps > MaxBps {
		return Result{}, errors.New("trust: share must be within 0..10000 bps")
	}
	res := Result{TrustBps: make([]int64, len(in.Reviewers))}
	if len(in.Reviewers) == 0 {
		return res, nil
	}

	seen := map[address]bool{}
	sum := int64(0)
	counted := int64(0)
	for i, r := range in.Reviewers {
		if seen[r.Addr] {
			// A reviewer counts once, however many times they appear.
			continue
		}
		seen[r.Addr] = true
		t := TrustOf(r, in.Worker, p)
		res.TrustBps[i] = t
		sum += t
		counted++
	}
	res.AvgTrustBps = sum / counted

	points := p.Base * res.AvgTrustBps / MaxBps
	points = points * in.ShareBps / MaxBps
	if in.Poster == in.Worker {
		points = points * p.SelfFundedFactorBps / MaxBps
	}
	res.Points = points
	return res, nil
}

// Level names a score band. Levels are cosmetic; realms that gate on
// reputation should compare scores directly.
func Level(score int64) string {
	switch {
	case score >= 5000:
		return "Grandmaster"
	case score >= 2000:
		return "Master"
	case score >= 800:
		return "Artisan"
	case score >= 300:
		return "Journeyman"
	case score > 0:
		return "Apprentice"
	default:
		return "Newcomer"
	}
}
