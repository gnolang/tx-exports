package greeter

import "strings"

var greeting string

func Set(g string) {
	greeting = g
}

func Get() string {
	return greeting
}

func Render(_ string) string {
	if greeting == "" {
		greeting = "Hello, Gno!"
	}
	return strings.TrimSpace(greeting) + "\n"
}
