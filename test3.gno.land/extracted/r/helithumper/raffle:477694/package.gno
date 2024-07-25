package raffle

import (
  "gno.land/r/gc24/raffle"
  "fmt"
)

func init() {
  code := "uW9zngjSwE"
  fmt.Println(raffle.RegisterCode(code))
}
