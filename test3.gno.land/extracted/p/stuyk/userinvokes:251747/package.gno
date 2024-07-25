package userinvokes

import (
    "gno.land/p/demo/ufmt"
)

var user_invokes map[string]int

func Render(name string) string {
  if (!user_invokes) {
    user_invokes = make(map[string]int)
  }


  if (!user_invokes[name]) {
    user_invokes[name] += 1
  } else {
    user_invokes = 1
  }

  return fmt.Println("Total user invokes %d", user_invokes[name])
}
