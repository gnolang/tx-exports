package grantround

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
)

// parseEvaluators parses "evaluator:sponsor,evaluator:sponsor" into aligned
// lists. Evaluators must be unique; a sponsor may be the evaluator itself.
func parseEvaluators(s string) (evs []address, sponsors []address, err error) {
	if strings.TrimSpace(s) == "" {
		return nil, nil, errors.New("evaluator list is empty")
	}
	seen := map[string]bool{}
	for _, part := range strings.Split(s, ",") {
		kv := strings.Split(strings.TrimSpace(part), ":")
		e := address(strings.TrimSpace(kv[0]))
		if !e.IsValid() {
			return nil, nil, errors.New("invalid evaluator address " + part)
		}
		if len(kv) != 2 {
			return nil, nil, errors.New("evaluator needs a designated sponsor (evaluator:sponsor), got " + part)
		}
		sp := address(strings.TrimSpace(kv[1]))
		if !sp.IsValid() {
			return nil, nil, errors.New("invalid sponsor address in " + part)
		}
		if seen[e.String()] {
			return nil, nil, errors.New("duplicate evaluator " + part)
		}
		seen[e.String()] = true
		evs = append(evs, e)
		sponsors = append(sponsors, sp)
	}
	return evs, sponsors, nil
}

// parseRule builds a rule from call arguments. criteria is "name:weight,name:weight";
// method is "weighted" or "majority"; tie is "lowest" or "refund".
func parseRule(method, criteria string, quorum int, tie, rationale string) (rulecalc.Rule, error) {
	r := rulecalc.Rule{Quorum: quorum, Rationale: rationale}
	switch method {
	case "weighted":
		r.Method = rulecalc.WeightedSum
	case "majority":
		r.Method = rulecalc.MajorityFirst
	default:
		return r, errors.New("method must be weighted or majority")
	}
	switch tie {
	case "lowest":
		r.Tie = rulecalc.LowestID
	case "refund":
		r.Tie = rulecalc.Refund
	default:
		return r, errors.New("tie must be lowest or refund")
	}
	if strings.TrimSpace(criteria) == "" {
		return r, errors.New("criteria are empty")
	}
	for _, part := range strings.Split(criteria, ",") {
		kv := strings.Split(strings.TrimSpace(part), ":")
		if len(kv) != 2 || kv[0] == "" {
			return r, errors.New("criterion must be name:weight, got " + part)
		}
		w, err := strconv.Atoi(kv[1])
		if err != nil {
			return r, errors.New("criterion weight is not a number: " + part)
		}
		r.Criteria = append(r.Criteria, rulecalc.Criterion{Name: kv[0], Weight: w})
	}
	return r, nil
}

// parseApps parses one "Title|PkgPath|Payout" line per application, joined by
// "\n" — the same lines rulecalc.AppsDigest hashes.
func parseApps(s string) ([]rulecalc.App, error) {
	if s == "" {
		return nil, errors.New("application list is empty")
	}
	var out []rulecalc.App
	for _, line := range strings.Split(s, "\n") {
		f := strings.Split(line, "|")
		if len(f) != 3 || f[0] == "" || f[1] == "" {
			return nil, errors.New("application must be Title|PkgPath|Payout, got " + line)
		}
		payout := address(f[2])
		if !payout.IsValid() {
			return nil, errors.New("invalid payout address in " + line)
		}
		out = append(out, rulecalc.App{Title: f[0], PkgPath: f[1], Payout: payout})
	}
	return out, nil
}

// parseScores parses "c0,c1;c0,c1": apps separated by ";", criteria by ",".
func parseScores(s string) ([][]int, error) {
	if strings.TrimSpace(s) == "" {
		return nil, errors.New("scores are empty")
	}
	var out [][]int
	for _, app := range strings.Split(s, ";") {
		var row []int
		for _, v := range strings.Split(strings.TrimSpace(app), ",") {
			n, err := strconv.Atoi(strings.TrimSpace(v))
			if err != nil {
				return nil, errors.New("score is not a number: " + v)
			}
			row = append(row, n)
		}
		out = append(out, row)
	}
	return out, nil
}
