package bouncer

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// The census: aggregate numbers from scanning the most active realms on a
// network (bouncer census). It names no realm, by design: findings on a
// specific mainnet realm go to its author privately. The realm stores only
// numbers, so a census cannot carry a name even by mistake.

// CensusRule is one rule's census numbers.
type CensusRule struct {
	Rule     string
	Realms   int // realms with at least one finding
	Findings int
	Proven   int
}

// Census is the latest published census.
type Census struct {
	Network        string
	RulesetHash    string
	FromHeight     int64 // exclusive
	ToHeight       int64
	From, To       int64 // unix seconds of the window's blocks
	Ranked         int   // realms taken from the top of the activity ranking
	Active         int   // realms with any call in the window
	Scanned        int
	Unavailable    int
	Files          int
	WithFindings   int
	WithProven     int
	CriticalOrHigh int
	MeanScoreX10   int    // mean score, times 10
	Grades         [5]int // A, B, C, D, F
	Clear          int
	Review         int
	NotRecommended int
	Rules          []CensusRule
	Attester       address
	Height         int64
}

var (
	census    Census
	hasCensus bool
)

const maxCensusCount = 1000000

// PublishCensus records census numbers. Attesters only. stats is a
// ";"-separated list of key=value entries, every key below exactly once:
//
//	ranked active scanned unavailable files with_findings with_proven
//	critical_or_high mean_score_x10 grade.A ... grade.F verdict.clear
//	verdict.review verdict.not-recommended
//
// plus "rule.<RULE>=<realms>/<findings>/<proven>" for each rule. Values are
// whole numbers; totals must add up.
func PublishCensus(cur realm, network, rulesetHash string, fromHeight, toHeight, from, to int64, stats string) {
	attester := assertAttester(cur)
	if !isToken(network) {
		panic("invalid network")
	}
	if !isHex64(rulesetHash) {
		panic("invalid rule-set hash")
	}
	if fromHeight < 0 || toHeight <= fromHeight || from <= 0 || to < from {
		panic("invalid window")
	}
	c := parseCensus(stats)
	c.Network, c.RulesetHash = network, rulesetHash
	c.FromHeight, c.ToHeight, c.From, c.To = fromHeight, toHeight, from, to
	c.Attester = attester
	c.Height = runtime.ChainHeight()
	census, hasCensus = c, true
	chain.Emit("CensusPublished", "network", network, "scanned", strconv.Itoa(c.Scanned), "attester", attester.String())
}

// LatestCensus returns a copy of the latest census.
func LatestCensus() (Census, bool) {
	c := census
	c.Rules = append([]CensusRule{}, census.Rules...)
	return c, hasCensus
}

var censusKeys = []string{
	"ranked", "active", "scanned", "unavailable", "files", "with_findings", "with_proven",
	"critical_or_high", "mean_score_x10", "grade.A", "grade.B", "grade.C", "grade.D", "grade.F",
	"verdict.clear", "verdict.review", "verdict.not-recommended",
}

func parseCensus(s string) Census {
	if len(s) > 4000 {
		panic("census stats too long")
	}
	vals := map[string]int{}
	var c Census
	for _, e := range strings.Split(s, ";") {
		k, v, ok := strings.Cut(e, "=")
		if !ok {
			panic("census entry must be key=value: " + e)
		}
		if rule, ok := strings.CutPrefix(k, "rule."); ok {
			if !isRuleID(rule) {
				panic("invalid rule id: " + rule)
			}
			for _, r := range c.Rules {
				if r.Rule == rule {
					panic("duplicate census key: " + k)
				}
			}
			parts := strings.Split(v, "/")
			if len(parts) != 3 {
				panic("rule entry must be realms/findings/proven: " + e)
			}
			r := CensusRule{Rule: rule, Realms: censusInt(parts[0]), Findings: censusInt(parts[1]), Proven: censusInt(parts[2])}
			if r.Realms > r.Findings || r.Proven > r.Findings || (r.Findings > 0) != (r.Realms > 0) {
				panic("inconsistent rule entry: " + e)
			}
			c.Rules = append(c.Rules, r)
			continue
		}
		known := false
		for _, ck := range censusKeys {
			known = known || ck == k
		}
		if !known {
			panic("unknown census key: " + k)
		}
		if _, dup := vals[k]; dup {
			panic("duplicate census key: " + k)
		}
		vals[k] = censusInt(v)
	}
	for _, k := range censusKeys {
		if _, ok := vals[k]; !ok {
			panic("missing census key: " + k)
		}
	}
	c.Ranked, c.Active, c.Scanned, c.Unavailable = vals["ranked"], vals["active"], vals["scanned"], vals["unavailable"]
	c.Files, c.WithFindings, c.WithProven = vals["files"], vals["with_findings"], vals["with_proven"]
	c.CriticalOrHigh, c.MeanScoreX10 = vals["critical_or_high"], vals["mean_score_x10"]
	c.Grades = [5]int{vals["grade.A"], vals["grade.B"], vals["grade.C"], vals["grade.D"], vals["grade.F"]}
	c.Clear, c.Review, c.NotRecommended = vals["verdict.clear"], vals["verdict.review"], vals["verdict.not-recommended"]

	grades := 0
	for _, g := range c.Grades {
		grades += g
	}
	switch {
	case c.Scanned+c.Unavailable != c.Ranked, c.Ranked > c.Active:
		panic("census totals do not add up: ranked, scanned, unavailable, active")
	case grades != c.Scanned, c.Clear+c.Review+c.NotRecommended != c.Scanned:
		panic("census totals do not add up: grades and verdicts must each sum to scanned")
	case c.WithFindings > c.Scanned, c.WithProven > c.WithFindings, c.CriticalOrHigh > c.WithFindings:
		panic("census totals do not add up: realms with findings")
	case c.MeanScoreX10 > 1000:
		panic("mean score out of range")
	}
	for _, r := range c.Rules {
		if r.Realms > c.WithFindings {
			panic("census totals do not add up: rule " + r.Rule)
		}
	}
	return c
}

func censusInt(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 || n > maxCensusCount || s != strconv.Itoa(n) {
		panic("invalid census number: " + s)
	}
	return n
}

func renderCensus() string {
	var b strings.Builder
	b.WriteString("# Census\n\n")
	if !hasCensus {
		b.WriteString("No census published yet.\n")
		return b.String()
	}
	c := census
	b.WriteString("Bouncer scanned the " + strconv.Itoa(c.Ranked) + " most active realms on " + sanitize.InlineCode(c.Network) + ": the ones called in the most successful transactions between " +
		date(c.From) + " and " + date(c.To) + " (blocks " + strconv.FormatInt(c.FromHeight+1, 10) + " to " + strconv.FormatInt(c.ToHeight, 10) + "). " +
		strconv.Itoa(c.Active) + " realms were called at all in that window.\n\n")
	b.WriteString("**Aggregate numbers only.** The census names no realm. Findings go to each realm's author privately.\n\n")
	b.WriteString("<gno-columns>\n\n")
	b.WriteString("| | Realms |\n| --- | --- |\n")
	row := func(k string, n int) { b.WriteString("| " + k + " | " + strconv.Itoa(n) + " |\n") }
	row("Scanned", c.Scanned)
	row("With any finding", c.WithFindings)
	row("With a Critical or High finding", c.CriticalOrHigh)
	row("With a PROVEN finding", c.WithProven)
	b.WriteString("\n<gno-columns-sep />\n\n")
	b.WriteString("| Grade | Realms |\n| --- | --- |\n")
	for i, g := range []string{"A", "B", "C", "D", "F"} {
		row(g, c.Grades[i])
	}
	b.WriteString("\n<gno-columns-sep />\n\n")
	b.WriteString("| Verdict | Realms |\n| --- | --- |\n")
	row(verdictText(VerdictClear), c.Clear)
	row(verdictText(VerdictReview), c.Review)
	row(verdictText(VerdictNotRecommended), c.NotRecommended)
	b.WriteString("\n</gno-columns>\n\n")
	b.WriteString("Mean score: **" + strconv.Itoa(c.MeanScoreX10/10) + "." + strconv.Itoa(c.MeanScoreX10%10) + "** / 100 over " + strconv.Itoa(c.Files) + " files.")
	if c.Unavailable > 0 {
		b.WriteString(" " + strconv.Itoa(c.Unavailable) + " ranked realms could not be fetched or parsed.")
	}
	b.WriteString("\n\n## By rule\n\n| Rule | Realms | Findings | PROVEN |\n| --- | --- | --- | --- |\n")
	for _, r := range c.Rules {
		rule := r.Rule
		for _, w := range wantedRules {
			if w == r.Rule {
				rule = "[" + r.Rule + "](" + webPath() + ":wanted/" + r.Rule + ")"
			}
		}
		b.WriteString("| " + rule + " | " + strconv.Itoa(r.Realms) + " | " + strconv.Itoa(r.Findings) + " | " + strconv.Itoa(r.Proven) + " |\n")
	}
	b.WriteString("\nScores here leave out dependencies. Rule set " + sanitize.InlineCode(c.RulesetHash[:12]) + ", published at block " + strconv.FormatInt(c.Height, 10) + ".\n\n")
	b.WriteString("_" + Disclaimer + "_\n")
	return b.String()
}
