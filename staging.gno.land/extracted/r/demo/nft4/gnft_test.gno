package gnft

import (
	"std"
	"testing"
)

func TestGNFT(t *testing.T) {
	// mint > gnft > set token uri > transfer to
	println("TEST_(std.CurrentRealm():", std.CurrentRealm())
	std.TestSetRealm(std.CurrentRealm())

	tid := AMint()
	owner := OwnerOf(tid)
	println("OWNER:", owner)
}
