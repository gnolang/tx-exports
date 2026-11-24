package gauntlet

// Report is the result of grading one solution.
type Report struct {
	Passed int
	Total  int
	// Details of the first failing test, if any.
	FailIn   string
	FailGot  string
	FailWant string
}

// OK reports whether every test passed.
func (r Report) OK() bool { return r.Total > 0 && r.Passed == r.Total }

// GradeCases runs solve against fixed cases. It stops at the first failure:
// a solution either passes everything or it does not.
func GradeCases(cases []Case, solve Solver) Report {
	r := Report{Total: len(cases)}
	for _, c := range cases {
		got := solve(c.In)
		if got != c.Want {
			r.FailIn, r.FailGot, r.FailWant = c.In, got, c.Want
			return r
		}
		r.Passed++
	}
	return r
}

// GradeJudge runs solve against inputs generated from seed and checked by the
// judge.
func GradeJudge(j *Judge, seed uint64, solve Solver) Report {
	ins := j.Inputs(seed)
	if len(ins) > MaxCases {
		ins = ins[:MaxCases]
	}
	r := Report{Total: len(ins)}
	for _, in := range ins {
		got := solve(in)
		if !j.Check(in, got) {
			r.FailIn, r.FailGot = in, got
			return r
		}
		r.Passed++
	}
	return r
}
