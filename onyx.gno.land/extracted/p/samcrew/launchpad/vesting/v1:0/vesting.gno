// Package vesting computes cliff-then-linear token release.
package vesting

import sm "gno.land/p/samcrew/launchpad/safemath/v1"

type Schedule struct {
	Total    int64
	Start    int64 // unix seconds
	Cliff    int64 // seconds after Start before anything vests
	Duration int64 // seconds after Start when everything has vested
}

func (s Schedule) Validate() {
	if s.Total <= 0 || s.Start < 0 || s.Duration <= 0 || s.Cliff < 0 || s.Cliff > s.Duration {
		panic("launchpad/vesting: invalid schedule")
	}
	sm.Add(s.Start, s.Duration)
}

func (s Schedule) VestedAt(now int64) int64 {
	s.Validate()
	if now < sm.Add(s.Start, s.Cliff) {
		return 0
	}
	elapsed := now - s.Start
	if elapsed >= s.Duration {
		return s.Total
	}
	return sm.MulDiv(s.Total, elapsed, s.Duration)
}

func (s Schedule) Releasable(now, released int64) int64 {
	return sm.Sub(s.VestedAt(now), released)
}
