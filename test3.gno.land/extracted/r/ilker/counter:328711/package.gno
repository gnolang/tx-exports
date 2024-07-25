package counter 

import "gno.land/p/demo/ufmt"

var val int

func Inc() {
  val++
}

func Dec() {
  val--
}

func Render(path string) string {
  return ufmt.Sprintf("value is: %d", val)
}
