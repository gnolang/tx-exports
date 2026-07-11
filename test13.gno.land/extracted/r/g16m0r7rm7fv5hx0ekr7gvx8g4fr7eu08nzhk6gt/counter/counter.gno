package counter

import (
	"strconv"
)

var count int

func Increment(_ realm, delta int) int {
	count += delta
	return count
}

func Render(path string) string {
	return "Current count: " + strconv.Itoa(count)
}
