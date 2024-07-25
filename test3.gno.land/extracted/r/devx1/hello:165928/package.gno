package hello

import (
  "gno.land/p/demo/rand"
  "strconv"
)

func Render(path string) string {
  instance := rand.New()
  num := instance.Int()

  return strconv.Itoa(num)
}
