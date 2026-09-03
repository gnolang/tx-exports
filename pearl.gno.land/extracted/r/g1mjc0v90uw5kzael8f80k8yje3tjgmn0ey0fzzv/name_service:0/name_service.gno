package name_service

import "strings"

type Registry map[string]string

var names Registry

func init() {
	names = make(Registry)
}

func Register(name, owner string) {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "" {
		panic("name cannot be empty")
	}
	if _, exists := names[name]; exists {
		panic("name already registered")
	}
	names[name] = owner
}

func Resolve(name string) string {
	return names[strings.ToLower(strings.TrimSpace(name))]
}

func Render(_ string) string {
	out := "registered names:\n"
	for n, o := range names {
		out += "  " + n + " -> " + o + "\n"
	}
	return out
}
