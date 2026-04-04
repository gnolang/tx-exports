package builders

import "chain/runtime"

var (
	admin       address
	submissions []*Submission
	webPath     string = "r/examples/builders"
)

func init() {
	admin = "g1778y2yphxs2wpuaflsy5y9qwcd4gttn4g5yjx5"
}

func Admin() address {
	return admin
}

func applicantAddr() address {
	return runtime.OriginCaller()
}

func requireAdmin() {
	if runtime.OriginCaller() != admin {
		panic("admin only")
	}
}

func GetSubmission(addr address) *Submission {
	for _, sub := range submissions {
		if sub.Applicant == addr {
			return sub
		}
	}
	return nil
}

func MySubmission() *Submission {
	return GetSubmission(applicantAddr())
}

func setSubmission(sub *Submission) {
	for i, existing := range submissions {
		if existing.Applicant == sub.Applicant {
			submissions[i] = sub
			return
		}
	}
	submissions = append(submissions, sub)
}

func TotalSubmissions() int {
	return len(submissions)
}

func SubmissionAt(i int) *Submission {
	if i < 0 || i >= len(submissions) {
		panic("index out of range")
	}
	return submissions[i]
}

func TotalApproved() int {
	count := 0
	for _, sub := range submissions {
		if sub.Status == StatusApproved || sub.Status == StatusPaid {
			count++
		}
	}
	return count
}

func TotalPaid() int {
	count := 0
	for _, sub := range submissions {
		if sub.Status == StatusPaid {
			count++
		}
	}
	return count
}
