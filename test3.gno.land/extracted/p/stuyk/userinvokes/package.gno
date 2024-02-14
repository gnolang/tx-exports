package userinvokes

import "fmt"

var user_invokes make([string]int)

func Render(name string) string {
  if _, exist := user_invokes[name] {
    user_invokes[name] += 1
  } else {
    user_invokes = 1
  }

  return fmt.Println("Total user invokes %d", user_invokes[name])
}
