package counter

import "strconv"

var count int

func Increment(n int) int {
	count += n
	return count
}

func Reset() {
	count = 0
}

func Get() int {
	return count
}

func Render(_ string) string {
	return "count: " + strconv.Itoa(count) + "\n"
}
