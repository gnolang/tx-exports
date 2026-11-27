// Package sample_consumer proves that other projects can reuse Aegis Pit:
//   - it imports the pure package /p/aegispit/aegis_core (policy + duel engine)
//   - it reads TrustScore from the /r/aegispit/aegis_pit realm
package sample_consumer

import (
	"strconv"

	core "gno.land/p/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_core"
	pit "gno.land/r/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_pit/v2"
)

// MinTrust is the reputation required to enter the VIP table.
const MinTrust int64 = 520

var (
	vip      []address
	lastDuel string
)

// CheckSpend runs an arbitrary spend through an aegis_core Policy
// that only allows tipping the bartender up to 50 ugnot.
func CheckSpend(bartender, target address, fn string, amt int64) string {
	p, err := core.NewPolicy(string(bartender), "Tip", 50, 0)
	if err != nil {
		return "policy error: " + err.Error()
	}
	if err := core.ValidateSpend(p, target, fn, amt, 0); err != nil {
		return "DENIED: " + err.Error()
	}
	return "OK"
}

// PracticeDuel uses the same deterministic engine as the arena.
func PracticeDuel(cur realm, movesA, movesB string) int {
	if err := core.ValidateMoves(movesA); err != nil {
		panic(err.Error())
	}
	if err := core.ValidateMoves(movesB); err != nil {
		panic(err.Error())
	}
	w, _ := core.ResolveDuel(movesA, movesB)
	lastDuel = movesA + " vs " + movesB + " → winner " + strconv.Itoa(w)
	return w
}

// EnterVIP gates access on the caller's Aegis Pit trust score.
func EnterVIP(cur realm) {
	who := cur.Previous().Address()
	score := pit.TrustScore(who)
	if score < MinTrust {
		panic("trust " + strconv.FormatInt(score, 10) + " < " + strconv.FormatInt(MinTrust, 10) + ": win a ranked match in Aegis Pit first")
	}
	vip = append(vip, who)
}

func Render(path string) string {
	out := "# 🍺 Sample Consumer — The VIP Table\n\n"
	out += "This realm imports `gno.land/p/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_core` and reads `TrustScore` from `gno.land/r/g1tjs9agmvxqn4r245avwht57j8jgy5sapxq96ym/aegis_pit/v2`.\n\n"
	out += "- VIP entry needs trust ≥ " + strconv.FormatInt(MinTrust, 10) + "\n"
	out += "- VIP guests: " + strconv.Itoa(len(vip)) + "\n"
	if lastDuel != "" {
		out += "- Last practice duel: " + lastDuel + "\n"
	}
	return out
}
