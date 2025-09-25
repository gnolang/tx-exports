package hello

import "strconv"

var count int

func Increment() {
	count += 1
}

func Render(path string) string {
	return "Count: " + strconv.Itoa(count)
}
