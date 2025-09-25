package dao

import (
	"math"
	"time"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/ufmt"
)

type (
	// DurationIterFn defines the a callback to iterate duration values.
	DurationIterFn func(name string, _ time.Duration) bool

	// DurationParams contains duration values for different parameters.
	DurationParams struct {
		params avl.Tree
	}
)

// Set sets or updates a parameter value.
func (p *DurationParams) Set(name string, v time.Duration) bool {
	return p.params.Set(name, v)
}

// Get gets a parameter value.
func (p DurationParams) Get(name string) (_ time.Duration, found bool) {
	if v, found := p.params.Get(name); found {
		return v.(time.Duration), true
	}
	return 0, false
}

// Size returns the number of duration parameters.
func (p DurationParams) Size() int {
	return p.params.Size()
}

// Iterate iterates duration parameter values.
func (p DurationParams) Iterate(fn DurationIterFn) bool {
	return p.params.Iterate("", "", func(name string, v interface{}) bool {
		return fn(name, v.(time.Duration))
	})
}

// HumanizeDuration returns a friendlier text representation of a duration.
func HumanizeDuration(d time.Duration) string { // TODO: Change to use singular/plurals
	if d == 0 {
		return ""
	}

	if sec := d.Seconds(); sec < 60 {
		return ufmt.Sprintf("%d seconds", int(sec))
	}

	if m := d.Minutes(); m < 60 {
		sec := math.Mod(d.Seconds(), 60)
		if sec < 1 {
			return ufmt.Sprintf("%d minutes", int(m))
		}
		return ufmt.Sprintf("%d minutes %d seconds", int(m), int(sec))
	}

	if hs := d.Hours(); hs < 24 {
		m := math.Mod(d.Minutes(), 60)
		if m < 1 {
			return ufmt.Sprintf("%d hours", int(hs))
		}

		sec := math.Mod(d.Seconds(), 60)
		if sec < 1 {
			return ufmt.Sprintf("%d hours %d minutes", int(hs), int(m))
		}
		return ufmt.Sprintf("%d hours %d minutes %d seconds", int(hs), int(m), int(sec))
	}

	days := d.Hours() / 24
	hs := math.Mod(d.Hours(), 24)
	if hs < 1 {
		return ufmt.Sprintf("%d days", int(days))
	}

	m := math.Mod(d.Minutes(), 60)
	if m < 0 {
		return ufmt.Sprintf("%d days %d hours", int(days), int(hs))
	}

	sec := math.Mod(d.Seconds(), 60)
	if sec < 1 {
		return ufmt.Sprintf("%d days %d hours %d minutes", int(days), int(hs), int(m))
	}
	return ufmt.Sprintf("%d days %d hours %d minutes %d seconds", int(days), int(hs), int(m), int(sec))
}
