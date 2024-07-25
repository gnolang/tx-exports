// hello1.gno

package hello

func Hello() string {
	return "Hello() called"
}

// func Render() string {
// 	return "Render() called"
// }

func Render(path string) string {
	return "Render(path string) called with\n# " + path
}

