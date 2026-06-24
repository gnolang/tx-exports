package hello

var message = "Hello, World!"

func Render(_ string) string {
	return "# " + message + "\n\nWelcome to my first Gno realm."
}
