package testdeploy

import "chain/runtime"

var admin address

func init() {
	admin = runtime.OriginCaller()
}

func Render(path string) string {
	return "# Test DAO\nAdmin: " + string(admin)
}
