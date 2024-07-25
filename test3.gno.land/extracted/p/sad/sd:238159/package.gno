package greeting

var (
  greeting string
)

func Setgreeting(msg string)  {
  greeting = msg
}

func Getgreeting() string {
  return greeting
} 