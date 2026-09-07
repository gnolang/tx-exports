package counter

import "strconv"

var count int

func Increment() int {
	count++
	return count
}

func Render(path string) string {
	return "Count: " + strconv.Itoa(count)
}
