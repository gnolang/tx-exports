package whitelist

import (
	"std"
	"testing"

	"gno.land/p/demo/testutils"
)

func TestWhitelist_Setup(t *testing.T) {
	var (
		name     = "First whitelist!"
		deadline = std.GetHeight() + 100 // get future height
		maxUsers = 100
	)

    // generate mock address
	alice := testutils.TestAddress("alice")

    // use mock address to execute test transaction
	std.TestSetOrigCaller(alice)

	w := NewWhitelist(name, deadline, maxUsers, alice)

	if w.GetWhitelistOwner() != alice {
		t.Fatal("invalid whitelist owner")
	}

	if w.GetMaxUsers() != maxUsers {
		t.Fatal("invalid max user number")
	}

	if w.GetWhitelistDeadline() != deadline {
		t.Fatal("invalid deadline")
	}

	if len(w.GetWhitelistedUsers()) != 0 {
		t.Fatal("invalid whitelisted user list")
	}
}


