package raffle

import "gno.land/r/gc24/raffle"

var codeout string
var nameout string
func init() {
	// Set admin address
	out := raffle.RegisterCode("isj8mLbHZF")
  println(out)

  name := raffle.RegisterUsername("urjitbhatia")
  println(name)

  codeout = out
  nameout = name
}

func Render(path string) string {
  return codeout + "    " + nameout
}
