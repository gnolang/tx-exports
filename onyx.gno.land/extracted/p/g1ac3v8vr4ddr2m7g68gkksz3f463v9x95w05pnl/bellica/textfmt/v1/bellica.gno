package textfmt

import (
	"strconv"
	"strings"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/rankpay/v1"
	"gno.land/p/nt/ufmt/v0"
)

const MinPot int64 = 1_000_000 // 1 GNOT

const MaxPlaces = rankpay.MaxPlaces

const MaxDuration = 60 * 24 * 60 // 60 days, in minutes

const MaxText = 280

const MaxURL = 256

func MustReason(reason string) string {
	reason = Clean(reason)
	MustLen("reason", reason, 3, MaxText)
	return reason
}

func MustLen(field, s string, min, max int) {
	if len(s) < min || len(s) > max {
		panic(ufmt.Sprintf("%s must be %d-%d characters", field, min, max))
	}
	if strings.ContainsAny(s, "\n\r") {
		panic(field + " must be a single line")
	}
}

// clean drops characters that can spoof or break rendered text (AUDIT F1):
// C0/C1 controls (except line breaks, which mustLen rejects with a clear
// message), DEL, bidi embeddings/overrides/isolates and marks, zero-width
// spaces and BOM. Tabs become spaces; invalid UTF-8 becomes U+FFFD. The result
// is trimmed. Applied to every user string at input.
func Clean(s string) string {
	var sb strings.Builder
	for _, r := range s { // ranging yields U+FFFD for invalid bytes
		switch {
		case r == '\n' || r == '\r' || r == 0x85 || r == 0x2028 || r == 0x2029:
			sb.WriteRune('\n') // rejected by mustLen as a line break
		case r == '\t':
			sb.WriteRune(' ')
		case r < 0x20 || (r >= 0x7f && r <= 0x9f):
		case r == 0x061c || r == 0x200b || r == 0x200e || r == 0x200f || r == 0x2060 || r == 0xfeff:
		case r >= 0x202a && r <= 0x202e:
		case r >= 0x2066 && r <= 0x2069:
		default:
			sb.WriteRune(r)
		}
	}
	return strings.TrimSpace(sb.String())
}

func Pad(n int64, w int) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < w {
		s = "0" + s
	}
	return s
}

func Key(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}
