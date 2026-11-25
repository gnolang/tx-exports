package hello

import "strconv"

var visits int

func Visit(_ realm) int {
	visits++
	return visits
}

func Render(_ string) string {
	return "# Hello, Gnome Tavern\n\nVisits: " + strconv.Itoa(visits)
}
