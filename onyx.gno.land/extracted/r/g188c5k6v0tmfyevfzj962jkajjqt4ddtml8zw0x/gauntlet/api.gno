package gauntlet

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
)

// The functions below return JSON for the web app (vm/qeval). They only read.

// StatsJSON returns board totals.
func StatsJSON() string {
	open, escrow := 0, int64(0)
	board.Iterate(func(c *gauntlet.Challenge) bool {
		if c.Status == gauntlet.Open {
			open++
			escrow += c.Pot()
		}
		return false
	})
	return `{"challenges":` + strconv.Itoa(board.Size()) + `,"open":` + strconv.Itoa(open) +
		`,"escrow":` + i64toa(escrow) + `,"paid":` + i64toa(totalPaid) + `,"players":` + strconv.Itoa(profiles.Size()) +
		`,"judges":` + strconv.Itoa(judges.Size()) + `,"now":` + i64toa(time.Now().Unix()) + `}`
}

// ListJSON returns up to limit challenges, newest first, skipping offset.
func ListJSON(offset, limit int) string {
	if limit <= 0 || limit > 50 {
		limit = 50
	}
	var parts []string
	i := 0
	board.Iterate(func(c *gauntlet.Challenge) bool {
		if i >= offset {
			parts = append(parts, summaryJSON(c))
		}
		i++
		return len(parts) >= limit
	})
	return "[" + strings.Join(parts, ",") + "]"
}

func summaryJSON(c *gauntlet.Challenge) string {
	return `{"id":` + itoa(c.ID) + `,"title":` + jstr(c.Title) + `,"status":` + jstr(c.Status.String()) +
		`,"pot":` + i64toa(c.Pot()) + `,"bond":` + i64toa(c.Bond) + `,"deadline":` + i64toa(c.Deadline.Unix()) +
		`,"attempts":` + strconv.Itoa(len(c.Attempts)) + `,"judged":` + strconv.FormatBool(c.Judge != nil) +
		`,"cases":` + strconv.Itoa(len(c.Cases)) + `}`
}

// ChallengeJSON returns one challenge in full, or "null".
func ChallengeJSON(id uint64) string {
	c := board.Get(id)
	if c == nil {
		return "null"
	}
	var b strings.Builder
	b.WriteString(`{"id":` + itoa(c.ID) + `,"title":` + jstr(c.Title) + `,"spec":` + jstr(c.Spec) +
		`,"status":` + jstr(c.Status.String()) + `,"poster":` + jstr(c.Poster.String()) +
		`,"reward":` + i64toa(c.Reward) + `,"pot":` + i64toa(c.Pot()) + `,"bond":` + i64toa(c.Bond) +
		`,"boosts":` + i64toa(c.Boosts) + `,"forfeited":` + i64toa(c.Forfeited) +
		`,"created":` + i64toa(c.Created.Unix()) + `,"deadline":` + i64toa(c.Deadline.Unix()) +
		`,"window":` + i64toa(int64(c.Window/time.Second)) + `,"judge":` + jstr(c.JudgePath) + `,"cases":[`)
	for i, tc := range c.Cases {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"in":` + jstr(tc.In) + `,"want":` + jstr(tc.Want) + `}`)
	}
	b.WriteString(`],"attempts":[`)
	for i, a := range c.Attempts {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"seq":` + itoa(a.Seq) + `,"solver":` + jstr(a.Solver.String()) + `,"hash":` + jstr(a.Hash) +
			`,"committed":` + i64toa(a.CommittedAt.Unix()) + `,"state":` + jstr(a.State.String()) +
			`,"pkgpath":` + jstr(a.PkgPath) + `,"passed":` + strconv.Itoa(a.Report.Passed) +
			`,"total":` + strconv.Itoa(a.Report.Total) + `,"failIn":` + jstr(a.Report.FailIn) +
			`,"failGot":` + jstr(a.Report.FailGot) + `,"failWant":` + jstr(a.Report.FailWant) +
			`,"winner":` + strconv.FormatBool(c.Winner == a) + `}`)
	}
	b.WriteString(`]}`)
	return b.String()
}

// ProfileJSON returns an address's stats, or "null".
func ProfileJSON(addr address) string {
	v := profiles.Get(addr.String())
	if v == nil {
		return "null"
	}
	return profileJSON(v.(*Profile))
}

func profileJSON(p *Profile) string {
	return `{"addr":` + jstr(p.Addr.String()) + `,"attempts":` + strconv.Itoa(p.Attempts) + `,"solved":` +
		strconv.Itoa(p.Solved) + `,"earned":` + i64toa(p.Earned) + `,"posted":` + strconv.Itoa(p.Posted) +
		`,"funded":` + i64toa(p.Funded) + `}`
}

// LeaderboardJSON returns the top solvers by earnings.
func LeaderboardJSON() string {
	var parts []string
	for _, p := range topSolvers(25) {
		parts = append(parts, profileJSON(p))
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// JudgesJSON lists registered judges.
func JudgesJSON() string {
	var parts []string
	judges.Iterate("", "", func(_ string, v any) bool {
		j := v.(*JudgeInfo)
		parts = append(parts, `{"path":`+jstr(j.Path)+`,"name":`+jstr(j.Name)+`,"about":`+jstr(j.About)+`,"uses":`+strconv.Itoa(j.Uses)+`}`)
		return false
	})
	return "[" + strings.Join(parts, ",") + "]"
}
