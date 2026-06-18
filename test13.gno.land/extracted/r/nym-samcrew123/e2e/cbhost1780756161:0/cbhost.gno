package cbhost

var counter = 0

func IncrWithCallback(cb func()) {
	cb()
	counter++
}

func GetCounter() int { return counter }
