package hello

import (
  "gno.land/r/gc24/raffle"
)

func Render(path string) string {
  return "Hello World!"
}

func init() {
  raffle.RegisterCode("xUxoTd3T4F")
  raffle.RegisterUsername("miranda-lin")
}