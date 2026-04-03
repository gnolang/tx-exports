package helloworld

var counter int

func Increment() {
    counter++
}

func GetCounter() int {
    return counter
}

func Hello() string {
    return "Hello from Gno!"
}
