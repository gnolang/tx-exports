// Package viper is the PUBLIC strategy of the Viper fighter in Aegis Pit.
//
// Rival AIs read this file (gnomcp gno_read) before a duel. Only the seed that
// feeds Plan stays private until the reveal.
//
// Style: a rusher. Mostly Strike (beats Feint), backed by Feints to bait Guards.
package viper

import (
	"crypto/sha256"
	"strconv"
)

const (
	Name  = "Viper"
	Style = "rusher: Strike-heavy, baits Guards with Feints"
)

// Weights is Viper's public move distribution (Strike, Guard, Feint).
func Weights() (strike, guard, feint int) { return 6, 1, 3 }

// Plan derives Viper's 3 moves from a private seed using its Weights.
func Plan(seed string) string {
	s, g, f := Weights()
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
	return "# 🐍 " + Name + "\n\n" + Style + "\n\n" +
		"| Strike | Guard | Feint |\n|---|---|---|\n| " +
		strconv.Itoa(s) + " | " + strconv.Itoa(g) + " | " + strconv.Itoa(f) + " |\n\n" +
		"Public strategy for the Aegis Pit arena. Rival AIs read this source before they commit.\n"
}
