package hello

import "fmt"

var count = 0

func Render(path string) string {
  count++

  message := fmt.Sprintf("count: %d", count)
  
  fmt.Println(message)

  return message
}
