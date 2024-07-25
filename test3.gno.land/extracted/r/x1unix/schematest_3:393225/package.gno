package schematest_3

func Render(path string) string {
  return "Hello World!"
}

func TestPrim(i int, bo bool, u8 uint8, i32 int32, f32 float32, f64 float64, str string) {
  println(i, bo, u8, i32, f32, f64, str)
}

func TestList(strs []uint8) {
  println(strs)
}