// Package broken does not compile, to show what gnoweb serves for a package
// that never goes live.
package broken

func Broken() int {
	return "not an int"
}
