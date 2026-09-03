package counter2

import "strconv"

var count int

func Increment(_ realm, n int) int {
	count += n
	return count
}

func Reset(_ realm) {
	count = 0
}

func Get() int {
	return count
}

func Render(_ string) string {
	return "count: " + strconv.Itoa(count) + "\n"
}
