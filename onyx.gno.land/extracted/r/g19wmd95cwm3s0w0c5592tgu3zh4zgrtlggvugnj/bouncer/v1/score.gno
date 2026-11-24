package bouncer

// The public, deterministic scoring formula (CLAUDE.md §8). The realm
// computes score, grade and verdict itself from the attested findings and
// dependency counts, so an attestation can never carry a score that
// contradicts its own findings.

// Labels, exactly as the prover writes them.
const (
	LabelProven        = "PROVEN"
	LabelNotReproduced = "NOT REPRODUCED"
	LabelStaticWarning = "STATIC WARNING"
)

// Severities.
const (
	SeverityCritical = "critical"
	SeverityHigh     = "high"
	SeverityMedium   = "medium"
)

// Verdicts.
const (
	VerdictNotRecommended = "not-recommended" // any PROVEN Critical or High
	VerdictReview         = "review"          // any Critical or High warning
	VerdictClear          = "clear"           // no known Critical or High issues
)

// Disclaimer is shown on every Passport.
const Disclaimer = "A high score means Bouncer found no issues with its current rules. It is not a guarantee of safety."

// Deps counts dependency trust for an attestation.
type Deps struct {
	DirectAtRisk   int
	IndirectAtRisk int
	Unverified     int
}

// computeScore applies the formula: start at 100, deduct, floor at 0.
func computeScore(fs []Finding, d Deps) int {
	score := 100
	for _, f := range fs {
		proven := f.Label == LabelProven
		switch {
		case proven && f.Severity == SeverityCritical:
			score -= 40
		case proven && f.Severity == SeverityHigh:
			score -= 25
		case f.Severity == SeverityCritical:
			score -= 15
		case f.Severity == SeverityHigh:
			score -= 10
		default: // medium, proven or not
			score -= 5
		}
	}
	score -= 10 * d.DirectAtRisk
	score -= 5 * d.IndirectAtRisk
	unverified := 2 * d.Unverified
	if unverified > 10 {
		unverified = 10
	}
	score -= unverified
	if score < 0 {
		score = 0
	}
	return score
}

func gradeOf(score int) string {
	switch {
	case score >= 90:
		return "A"
	case score >= 75:
		return "B"
	case score >= 60:
		return "C"
	case score >= 40:
		return "D"
	}
	return "F"
}

func verdictOf(fs []Finding) string {
	verdict := VerdictClear
	for _, f := range fs {
		if f.Severity != SeverityCritical && f.Severity != SeverityHigh {
			continue
		}
		if f.Label == LabelProven {
			return VerdictNotRecommended
		}
		verdict = VerdictReview
	}
	return verdict
}

// ScoreFor exposes the formula, so anyone can check an attestation or score
// a report before attesting it.
func ScoreFor(fs []Finding, d Deps) (score int, grade, verdict string) {
	score = computeScore(fs, d)
	return score, gradeOf(score), verdictOf(fs)
}
