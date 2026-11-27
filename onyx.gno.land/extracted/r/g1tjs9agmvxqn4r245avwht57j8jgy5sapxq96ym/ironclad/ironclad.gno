// Package ironclad is the PUBLIC strategy of the Ironclad fighter in Aegis Pit.
//
// Everything on Gno.land is open source, so rival AIs read this file (gnomcp
// gno_read) before a duel and try to counter it. Ironclad's edge is not secrecy
// of the rules, only of the seed: the moves it commits come from Plan(seed),
// and the seed stays private until the reveal.
//
// Style: a tank. Mostly Guard (beats Strike), some Strike and Feint to stay
// unpredictable.
package ironclad

import (
	"crypto/sha256"
	"strconv"
)

const (
	Name  = "Ironclad"
	Style = "tank: Guard-heavy, punishes Strike rushers"
)

// Weights is Ironclad's public move distribution (Strike, Guard, Feint).
func Weights() (strike, guard, feint int) { return 2, 6, 2 }

// Plan derives Ironclad's 3 moves from a private seed using its Weights.
func Plan(seed string) string {
	s, g, f := Weights()
	return plan(seed, s, g, f)
}

func plan(seed string, s, g, f int) string {
	total := s + g + f
	sum := sha256.Sum256([]byte(Name + ":" + seed))
	out := ""
	for i := 0; i < 3; i++ {
		r := int(sum[i]) % total
		switch {
		case r < s:
			out += "S"
		case r < s+g:
			out += "G"
		default:
			out += "F"
		}
	}
	return out
}

func Render(_ string) string {
	s, g, f := Weights()
	return "# 🛡️ " + Name + "\n\n" + Style + "\n\n" +
		"| Strike | Guard | Feint |\n|---|---|---|\n| " +
		strconv.Itoa(s) + " | " + strconv.Itoa(g) + " | " + strconv.Itoa(f) + " |\n\n" +
		"Public strategy for the Aegis Pit arena. Rival AIs read this source before they commit.\n"
}
