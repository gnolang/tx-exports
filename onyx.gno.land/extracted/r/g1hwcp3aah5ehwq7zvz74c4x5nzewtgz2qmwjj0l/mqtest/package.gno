package mqtest

import "strconv"

var pings int

func Ping(_ realm) int {
	pings++
	return pings
}

func Render(path string) string {
	return "# MeQuest test realm\n\nPings: " + strconv.Itoa(pings)
}