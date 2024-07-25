package userinvokes

import (
    "gno.land/p/demo/ufmt"
)

var user_invokes map[string]uint64

func Render(name string) string {
  if (!user_invokes[name]) {
    user_invokes[name] += 1
  } else {
    user_invokes = 1
  }

  return fmt.Println("Total user invokes %d", user_invokes[name])
}
