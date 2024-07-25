package greeting

var (
  greeting string
)

func SetGreeting(msg string) {
  greeting = msg
}

func GetGreeting() string {
  return greeting
}
