package crazy_timecapsule

import "strconv"

type Capsule struct {
	From    string
	Message string
	Block   int
}

var capsules []Capsule

func Bury(_ realm, from, message string, block int) int {
	idx := len(capsules)
	capsules = append(capsules, Capsule{From: from, Message: message, Block: block})
	return idx
}

func Render(_ string) string {
	out := "CRAZY TIME CAPSULE - " + strconv.Itoa(len(capsules)) + " buried\n"
	for i, c := range capsules {
		out += "  #" + strconv.Itoa(i) + " from " + c.From + ": " + c.Message + "\n"
	}
	return out
}
