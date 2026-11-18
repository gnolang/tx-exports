package hello

var message = "Hello from gno.land!"

func SetMessage(_ realm, msg string) {
	message = msg
}

func Render(path string) string {
	return "# " + message + "\n\nThis is a simple realm."
}
