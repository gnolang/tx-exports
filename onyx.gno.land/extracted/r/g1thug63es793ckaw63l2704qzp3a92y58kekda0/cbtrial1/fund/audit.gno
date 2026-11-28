package fund

import (
	"time"

	"gno.land/p/nt/ufmt/v0"
)

// AttestAnnualReport records the SHA-256 of the audited annual report for a
// fiscal year (calendar year, by block time) that has ended. Auditor only,
// master key, once per year. The report stays off-chain.
func AttestAnnualReport(cur realm, year int64, sha string) {
	onlyRole(cur, auditor, "auditor")
	checkCommitment(sha)
	cy := int64(time.Unix(now(), 0).Year())
	ly := int64(time.Unix(launchTime, 0).Year())
	if year < ly || year >= cy || year > lastFundYear() {
		panic("the year must have ended, and the fund must have existed in it")
	}
	if audits.Has(pad(year)) {
		panic("already recorded for this year")
	}
	audits.Set(pad(year), &auditRecord{year: year, sha: sha, height: heightNow()})
	addTrail("auditor", ufmt.Sprintf("Audited annual report for %d recorded: %s.", year, sha))
}

// auditStatus lists each ended fiscal year: recorded, due, or overdue (no
// report within 6 months of the year end).
func auditStatus() []string {
	var out []string
	if launchTime == 0 {
		return out
	}
	t := now()
	cy := int64(time.Unix(t, 0).Year())
	for y := int64(time.Unix(launchTime, 0).Year()); y < cy && y <= lastFundYear(); y++ {
		if v := audits.Get(pad(y)); v != nil {
			a := v.(*auditRecord)
			out = append(out, ufmt.Sprintf("| %d | recorded at height %d | `%s` |", y, a.height, a.sha))
			continue
		}
		yearEnd := time.Date(int(y)+1, time.January, 1, 0, 0, 0, 0, time.UTC).Unix()
		state := "due"
		if t > yearEnd+AuditDueDays*86400 {
			state = "**overdue**"
		}
		out = append(out, ufmt.Sprintf("| %d | %s | |", y, state))
	}
	return out
}

// lastFundYear is the last fiscal year the fund lived in: the closure year
// once closed (review 2, m12).
func lastFundYear() int64 {
	if closedAt > 0 {
		return int64(time.Unix(closedAt, 0).Year())
	}
	return 1 << 40
}

func launchYear() int64 { return int64(time.Unix(launchTime, 0).Year()) }
