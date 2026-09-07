package counter2

import "strconv"

var count int

func Increment(cur realm) int {
	count++
	return count
}

func Render(path string) string {
	return "Count: " + strconv.Itoa(count)
}
