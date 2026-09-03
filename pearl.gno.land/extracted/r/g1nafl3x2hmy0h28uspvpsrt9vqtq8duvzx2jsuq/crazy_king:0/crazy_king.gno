package crazy_king

import "strconv"

var king string
var throneCost int64
var usurpCount int

func init() {
	throneCost = 1000000
}

func ClaimThrone(_ realm, claimer string) string {
	king = claimer
	usurpCount++
	throneCost = throneCost * 110 / 100
	return king
}

func Render(_ string) string {
	out := "CRAZY KING OF THE HILL\n"
	if king == "" {
		out += "throne is empty!\n"
	} else {
		out += "current king: " + king + "\n"
	}
	out += "usurp count: " + strconv.Itoa(usurpCount) + "\n"
	return out
}
