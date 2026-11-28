// Package bad is a plausible but wrong intervals implementation: Add does
// not merge intervals that only touch, so Spans can return [1,3) [3,5)
// instead of [1,5). The fixed examples miss it; generated cases catch it.
package bad

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/specs/intervals/v1"

type set struct{ sp [][2]int }

// New returns an empty set.
func New() intervals.Set { return &set{} }

func (s *set) Add(lo, hi int) {
	if lo >= hi {
		return
	}
	var out [][2]int
	placed := false
	for _, p := range s.sp {
		switch {
		case p[1] <= lo:
			out = append(out, p)
		case p[0] >= hi:
			if !placed {
				out = append(out, [2]int{lo, hi})
				placed = true
			}
			out = append(out, p)
		default:
			if p[0] < lo {
				lo = p[0]
			}
			if p[1] > hi {
				hi = p[1]
			}
		}
	}
	if !placed {
		out = append(out, [2]int{lo, hi})
	}
	s.sp = out
}

func (s *set) Remove(lo, hi int) {
	if lo >= hi {
		return
	}
	var out [][2]int
	for _, p := range s.sp {
		if p[1] <= lo || p[0] >= hi {
			out = append(out, p)
			continue
		}
		if p[0] < lo {
			out = append(out, [2]int{p[0], lo})
		}
		if p[1] > hi {
			out = append(out, [2]int{hi, p[1]})
		}
	}
	s.sp = out
}

func (s *set) Contains(x int) bool {
	for _, p := range s.sp {
		if x >= p[0] && x < p[1] {
			return true
		}
	}
	return false
}

func (s *set) Spans() [][2]int {
	out := make([][2]int, len(s.sp))
	copy(out, s.sp)
	return out
}
