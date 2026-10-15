package counter

var count int

func Increment() int {
	count++
	return count
}

func Render(path string) string {
	return "Counter value: " + string(count)
}
