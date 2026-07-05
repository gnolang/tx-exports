package counter

import "strconv"

var count int

func Increment(_ realm) {
	count++
}

func Decrement(_ realm) {
	count--
}

func Reset(_ realm) {
	count = 0
}

func Render(_ string) string {
	return "# ruangnode counter\n\nCurrent count: **" + strconv.Itoa(count) + "**"
}
