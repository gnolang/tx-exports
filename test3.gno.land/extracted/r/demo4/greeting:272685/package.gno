package greeting

 // v0 https://play.gno.land/p/a0TSnNILBdL

var (
  greeting string
)

func SetGreeting(msg string) {
  greeting = msg
}

func GetGreeting() string {
  return greeting
}
 