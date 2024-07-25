package greeting

var (
  greeting string
)

// setters

func SetGreeting(msg string) {
  greeting = msg
}

// getters

func GetGreeting() string {
  return greeting
}
