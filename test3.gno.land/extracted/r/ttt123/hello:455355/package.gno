package hello

import "gno.land/p/demo/ufmt"
var x int

func Inc() string {
  x= x +1
  return  ufmt.Sprintf("Count x: %d", x)
}


