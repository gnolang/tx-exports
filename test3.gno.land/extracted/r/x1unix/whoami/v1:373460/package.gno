package v1

import (
	"gno.land/p/demo/ufmt"
	"std"
)

var (
	admin std.Address = ""
)

func init() {
	admin = ""
}

func AmIAdmin() string {
	actor := std.GetOrigCaller()
	return ufmt.Sprintf("Admin: %s\nCaller: %s\nIsAdmin: %t", actor == admin)
}

func Render(path string) string {
	return AmIAdmin()
}
