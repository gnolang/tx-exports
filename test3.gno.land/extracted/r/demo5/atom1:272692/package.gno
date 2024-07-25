package atom1

 // v0 https://play.gno.land/p/a0TSnNILBdL

var (
  atom1 string
)

func SetGreeting(msg string) {
  atom1 = msg
}

func GetGreeting() string {
  return atom1
}
 