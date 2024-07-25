package userinvokes

import (
    "gno.land/p/demo/ufmt"
)

var user_invokes = make(map[string]uint64)

func Render(name string) string {
  val, exists := user_invokes[name]

  if (exists) {
    user_invokes[name] += 1
  } else {
    user_invokes[name] = 1
  }

  return fmt.Println("Total user invokes %d", user_invokes[name])
}
