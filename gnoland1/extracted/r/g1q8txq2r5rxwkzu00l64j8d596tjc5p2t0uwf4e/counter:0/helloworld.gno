package helloworld

import "strconv"

var counter int

func init() {
    counter = 0
}

func Increment(cur realm) int {
    counter++
    return counter
}

func GetCounter() int {
    return counter
}

func Render(_ string) string {
    return "# Hello from Gno!\n\nCounter: " + strconv.Itoa(counter) + "\n"
}
