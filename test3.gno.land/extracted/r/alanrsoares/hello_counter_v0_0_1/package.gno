package hello

import "fmt"

var count = 0

func Increment() {
  count++

  message := fmt.Sprintf ("Count is: %d", count)

  fmt.Println(message)
}

func Render(path string) string {
  message := fmt.Sprintf ("Count is: %d", count)

  fmt.Println(message)

  return message
}
