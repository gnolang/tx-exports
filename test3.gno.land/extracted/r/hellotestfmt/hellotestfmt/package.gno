package hellotestfmt

import (

  "fmt"

)

func Render(path string) string {
  return fmt.Sprintf("Hello, %s", "World!")
}
