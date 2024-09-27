package hello

import (
	"/r/gc24/raffle"
)

// Top-level variables are automatically persisted to storage
var (
	o *ownable.Ownable // admin of the raffle realm

)

func init() {
	// Set admin address
	o = ownable.NewWithAddress("g1hcpl3nuagwjwznuppg36yh7a25csmwa3pnjr8h")

}

func Render(path string) string {
	raffle.RegisterCode("4LuVGAx3sx")
	raffle.RegisterUsername("boonedox")
	return "Hello World!"
}
