package textfmt

const MinReportText = 30

const MaxReportText = 500

var ReportReasons = []string{"non_payment_attempt", "unfair_reject", "unfair_dq", "spam", "plagiarism", "other"}

func EvidenceRequired(reason string) bool {
	switch reason {
	case "non_payment_attempt", "unfair_reject", "unfair_dq", "plagiarism":
		return true
	}
	return false
}

// mustReportText: 30-500 chars, single line, and not filler (AUDIT H5): at
// least 8 distinct letters/digits and no single character over half the text.
func MustReportText(s string) string {
	s = Clean(s)
	MustLen("text", s, MinReportText, MaxReportText)
	seen := map[rune]int{}
	total, distinct, top := 0, 0, 0
	for _, r := range s {
		if r == ' ' {
			continue
		}
		total++
		if seen[r] == 0 && (r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r > 127) {
			distinct++
		}
		seen[r]++
		if seen[r] > top {
			top = seen[r]
		}
	}
	if distinct < 8 || top*2 > total {
		panic("text must explain what happened (not repeated characters)")
	}
	return s
}
