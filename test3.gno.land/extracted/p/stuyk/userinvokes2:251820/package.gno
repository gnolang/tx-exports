package userinvokes2

var user_invokes = make(map[string]uint64)

func Render(name string) uint64 {
  val, exists := user_invokes[name]

  if (exists) {
    user_invokes[name] += 1
  } else {
    user_invokes[name] = 1
  }

  return user_invokes[name]
}
