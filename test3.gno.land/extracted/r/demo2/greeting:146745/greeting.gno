package greeting

var (
  greeting string
)

// setters -> tx (spend money, GNOT; ETH)
func SetGreeting(msg string) {
  greeting = msg
}

// getter -> query (read-only) = FREE
func GetGreeting() string {
  return greeting
}
