package demo

import "strings"

func Hello() string {
	return "Hello World and Welcome to Jumaru Realm!"
}

func greetings(name string) string { // private
	return "Jumaru says: Welcome, " + name + "!"
}

func Render(path string) string {
	switch {
	case path == "hello":
		return Hello()
	case strings.HasPrefix(path, "greetings/"):
		name := strings.Split(path, "/")[1] // take string after slash
		name = strings.Title(name)          // capitalize first letter
		return greetings(name)
	case path == "":
		out := "- [hello](/r/jumaru:hello)\n"
		out += "- [greetings/jumaru](/r/jumaru:greetings/jumaru)\n"
		return out
	}
	return "404"
}
