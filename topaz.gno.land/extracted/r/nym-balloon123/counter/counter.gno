package counter

var count int

func Increment() {
	count++
}

func GetCount() int {
	return count
}

func Render(path string) string {
	return "Counter: " + string(count)
}
