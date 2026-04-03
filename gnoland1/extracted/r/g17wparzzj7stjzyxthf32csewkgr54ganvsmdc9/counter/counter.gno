package counter

import "strconv"

var count int

func Increment(_ realm, change int) int {
	count += change
	return count
}

func Render(_ string) string {
	return "Current counter value: " + strconv.Itoa(count)
}
