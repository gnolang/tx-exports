package greeting

// v0 https://play.staging.gnosh.dev/p/KDsMud3OsSv

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
