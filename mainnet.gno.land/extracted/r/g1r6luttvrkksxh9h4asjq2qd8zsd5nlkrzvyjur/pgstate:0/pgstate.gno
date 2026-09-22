package pgstate
var n int64
func Inc(cur realm) { n++ }
func Render(path string) string { return "n" }
