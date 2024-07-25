package schematest_1

func Render(path string) string {
  return "Hello World!"
}

type S struct {
  Foo int
  Bar string
  Baz S
}

func TestArgs1(str string, i int, ui uint, u8 uint8, b byte, r rune, bo bool, s []bool, iface interface{}, st S, sts []S) {

}
