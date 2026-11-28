package verdict_counter

import "strconv"

var counter int64

func Increment(cur realm) {
	increment()
}

func increment() {
	if counter == int64(^uint64(0)>>1) {
		panic("counter overflow")
	}
	counter++
}

func Count() int64 {
	return counter
}

func Render(path string) string {
	return "Verdict counter: " + strconv.FormatInt(counter, 10)
}
