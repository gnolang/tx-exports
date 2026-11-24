package rulecalc

import (
	"errors"
	"strconv"
)

// Sheet is one evaluator's scores: Scores[app][criterion], apps ordered by ID 0..n-1,
// criteria in the order of Rule.Criteria.
type Sheet struct {
	Evaluator address
	Scores    [][]int
}

// ValidateSheet checks that s scores every app on every criterion within 0-10.
func ValidateSheet(r Rule, nApps int, s Sheet) error {
	if len(s.Scores) != nApps {
		return errors.New("rulecalc: sheet must score " + strconv.Itoa(nApps) + " apps")
	}
	for i, row := range s.Scores {
		if len(row) != len(r.Criteria) {
			return errors.New("rulecalc: app " + strconv.Itoa(i) + " needs " + strconv.Itoa(len(r.Criteria)) + " scores")
		}
		for _, v := range row {
			if v < MinScore || v > MaxScore {
				return errors.New("rulecalc: score out of range 0-10 for app " + strconv.Itoa(i))
			}
		}
	}
	return nil
}

func weighted(r Rule, row []int) int {
	sum := 0
	for c, v := range row {
		sum += r.Criteria[c].Weight * v
	}
	return sum
}

// argmax returns the lowest index holding the maximum and whether that maximum is shared.
func argmax(xs []int) (best int, tied bool) {
	for i := 1; i < len(xs); i++ {
		if xs[i] > xs[best] {
			best = i
			tied = false
		} else if xs[i] == xs[best] {
			tied = true
		}
	}
	return best, tied
}

// Totals returns the per-app figure the rule's method ranks by:
// weighted score sums for WeightedSum, first-place counts for MajorityFirst.
// Sheets must already pass ValidateSheet.
func Totals(r Rule, nApps int, sheets []Sheet) []int {
	tot := make([]int, nApps)
	for _, s := range sheets {
		switch r.Method {
		case WeightedSum:
			for app, row := range s.Scores {
				tot[app] += weighted(r, row)
			}
		case MajorityFirst:
			per := make([]int, nApps)
			for app, row := range s.Scores {
				per[app] = weighted(r, row)
			}
			first, _ := argmax(per) // in-sheet tie -> lowest ID
			tot[first]++
		}
	}
	return tot
}

// Compute returns the winning app ID. paid == false means the grant is refunded:
// no apps, fewer sheets than the quorum, or a top-level tie under the Refund tie-break.
// Sheets must already pass ValidateSheet.
func Compute(r Rule, nApps int, sheets []Sheet) (winner int, paid bool) {
	if nApps < 1 || len(sheets) < r.Quorum {
		return 0, false
	}
	best, tied := argmax(Totals(r, nApps, sheets))
	if tied && r.Tie == Refund {
		return 0, false
	}
	return best, true
}
