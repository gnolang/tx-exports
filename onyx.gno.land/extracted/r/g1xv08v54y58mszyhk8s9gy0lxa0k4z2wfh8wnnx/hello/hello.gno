package hello

// Toolchain smoke-test realm: proves addpkg + Render work end to end on Onyx.

var visits int

func Visit(_ realm) int {
	visits++
	return visits
}

func Render(_ string) string {
	return "# Hello from the Tavern\n\nToolchain check: this realm is live on Onyx (onyx-1)."
}
