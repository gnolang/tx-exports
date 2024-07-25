package greeting

import (
  "gno.land/p/demo/ufmt"
)

var (
  greeting string
)

// setters -> tx (spend money, GNOT; ETH)
func SetGreeting(msg string) {
  greeting = msg
}

// getter -> query (read-only) = FREE
func Greeting() string {
  return greeting
}

func Render(_ string) string {
  return ufmt.Sprintf("Hello %s!", greeting)
}
