package raffle2

import(
  "gno.land/r/gc24/raffle"
)

func init (){
  raffle.RegisterUsername("dInquisitor")
}

func Render(path string) string {
  return "Hello World!"
}
