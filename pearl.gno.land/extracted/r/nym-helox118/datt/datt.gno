package datt

import "strconv"

var count int

func Increment(_ realm ) int {
	count++
	return count
}

func Render(_ string) string {
	return "datt dari Pearl. Count: " + strconv.Itoa(count)
}
