package hello

var counter = 0

func Inc() {
  counter++
}

func Render(path string) string {
  return "Hello World!"
}
