package kolektif

import (
	"gno.land/p/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/kolektif/rosca"
)

// This file is the read-only surface of the realm. Any other realm, indexer or
// client can call these without a transaction and without a realm capability,
// which is what makes a Kolektif circle composable: a DAO can require
// "member in good standing of circle #7" before letting an address vote.

// CircleCount returns how many circles have ever been opened.
func CircleCount() uint64 {
	return uint64(len(circles))
}

// CircleSummary reports the core facts of a circle. It returns zero values and
// status "UNKNOWN" for an id that does not exist.
func CircleSummary(id uint64) (name string, contribution int64, size int, round int, status string, pool int64) {
	if id == 0 || int(id) > len(circles) {
		return "", 0, 0, 0, "UNKNOWN", 0
	}
	c := circles[id-1]
	return c.Name, c.Params.Contribution, c.Params.Size, c.Round, c.Status.String(), c.Pool
}

// IsMember reports whether addr holds a seat in circle id.
func IsMember(id uint64, addr address) bool {
	if id == 0 || int(id) > len(circles) {
		return false
	}
	return circles[id-1].Member(addr) != nil
}

// Standing reports a member's record. It returns zero values for a non-member.
func Standing(id uint64, addr address) (roundsPaid int, defaulted bool, received bool, collateral int64) {
	if id == 0 || int(id) > len(circles) {
		return 0, false, false, 0
	}
	m := circles[id-1].Member(addr)
	if m == nil {
		return 0, false, false, 0
	}
	return m.RoundsPaid, m.Defaulted, m.Received, m.Collateral
}

// GlobalStats returns the number of circles, the ugnot currently escrowed by
// all of them, and the ugnot paid out since deployment.
func GlobalStats() (count int, active int, escrowed int64, paidOut int64) {
	count = len(circles)
	for _, c := range circles {
		if c.Status == rosca.StatusActive {
			active++
		}
		escrowed += c.Pool
		paidOut += c.PaidOutTotal
	}
	return count, active, escrowed, paidOut
}
