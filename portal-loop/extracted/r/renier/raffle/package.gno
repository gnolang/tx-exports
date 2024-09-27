package raffle

import r "gno.land/r/gc24/raffle"

func init() {
  r.RegisterUsername("renier")
}

func Render(path string) string {
  return "Hello World!"
}
