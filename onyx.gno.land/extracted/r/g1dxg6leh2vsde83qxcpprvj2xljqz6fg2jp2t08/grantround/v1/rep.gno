package grantround

import (
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// Track is the public record of an evaluator or sponsor across settled rounds.
// Cancelled rounds do not count.
type Track struct {
	Accepted  int
	Fulfilled int
	Missed    int
}

func (t Track) String() string {
	return strconv.Itoa(t.Accepted) + "/" + strconv.Itoa(t.Fulfilled) + "/" + strconv.Itoa(t.Missed)
}

var tracks avl.Tree // address -> *Track

// TrackOf returns the record of addr (accepted/fulfilled/missed mandates).
func TrackOf(addr address) Track {
	v := tracks.Get(addr.String())
	if v == nil {
		return Track{}
	}
	return *(v.(*Track))
}

// openTrack returns the record of a, creating an empty one if there is none.
// Join calls it for the evaluator and the sponsor, so the joining sponsor pays
// the storage and Finalize only updates counters.
func openTrack(a address) *Track {
	if v := tracks.Get(a.String()); v != nil {
		return v.(*Track)
	}
	tr := &Track{}
	tracks.Set(a.String(), tr)
	return tr
}

func bump(a address, fulfilled bool) {
	tr := openTrack(a)
	tr.Accepted++
	if fulfilled {
		tr.Fulfilled++
	} else {
		tr.Missed++
	}
}

// recordTracks credits each joined evaluator and its sponsor once per settled
// round; a self-sponsored evaluator is counted once.
func recordTracks(r *Round) {
	for i, s := range r.Sponsors {
		if s == "" {
			continue
		}
		ok := r.Sheets[i] != nil
		bump(r.Evaluators[i], ok)
		if s != r.Evaluators[i] {
			bump(s, ok)
		}
	}
}
