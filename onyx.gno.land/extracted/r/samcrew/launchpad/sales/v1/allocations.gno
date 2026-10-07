package sales

import (
	"strconv"
	"strings"

	"chain"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/p/samcrew/launchpad/vesting/v1"
)

const (
	maxAllocationBytes = 8192
	maxAllocations     = 50
)

type allocation struct {
	beneficiary address
	amount      int64
	start       int64
	cliff       int64
	duration    int64
	revocable   bool
}

func decimal(s string) int64 {
	if s == "" || (len(s) > 1 && s[0] == '0') {
		panic("launchpad/sales: noncanonical allocation decimal")
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			panic("launchpad/sales: noncanonical allocation decimal")
		}
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("launchpad/sales: allocation decimal out of range")
	}
	return v
}

// parseAllocations accepts a single bounded, canonical MsgCall argument.
// Each record is address:amount:start:cliff:duration:revocable, with the
// address order providing both a stable encoding and duplicate rejection.
func parseAllocations(encoded string) ([]allocation, int64) {
	if len(encoded) > maxAllocationBytes {
		panic("launchpad/sales: allocations too large")
	}
	if encoded == "" {
		return nil, 0
	}
	records := strings.Split(encoded, ";")
	if len(records) > maxAllocations {
		panic("launchpad/sales: too many allocations")
	}
	out := make([]allocation, 0, len(records))
	var total int64
	previous := ""
	for _, record := range records {
		fields := strings.Split(record, ":")
		if len(fields) != 6 || fields[0] <= previous {
			panic("launchpad/sales: invalid allocation order or fields")
		}
		who := address(fields[0])
		if !meta.ValidAddress(who) || who == chain.PackageAddress(salesPath) {
			panic("launchpad/sales: invalid allocation address")
		}
		a := allocation{
			beneficiary: who,
			amount:      decimal(fields[1]),
			start:       decimal(fields[2]),
			cliff:       decimal(fields[3]),
			duration:    decimal(fields[4]),
		}
		if a.amount == 0 || (fields[5] != "0" && fields[5] != "1") {
			panic("launchpad/sales: invalid allocation amount or revocability")
		}
		a.revocable = fields[5] == "1"
		if a.duration == 0 {
			if a.start != 0 || a.cliff != 0 || a.revocable {
				panic("launchpad/sales: invalid immediate allocation")
			}
		} else {
			vesting.Schedule{Total: a.amount, Start: a.start, Cliff: a.cliff, Duration: a.duration}.Validate()
		}
		total = sm.Add(total, a.amount)
		out = append(out, a)
		previous = fields[0]
	}
	return out, total
}
