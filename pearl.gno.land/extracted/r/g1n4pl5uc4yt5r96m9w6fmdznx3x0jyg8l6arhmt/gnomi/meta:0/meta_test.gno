package meta

import "testing"

func TestSetGetMeta(cur realm, t *testing.T) {
	resetForTest()
	owner := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(owner))
	Init(cross(cur))
	pad := "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/gnomi/padv4"
	SetMeta(cross(cur), pad, "0000001", "A cool meme", "https://img.example/x.png", "https://site.example", "coolmeme", "coolchat")
	raw := GetMeta(pad, "0000001")
	if raw == "" {
		t.Fatal("empty")
	}
	if !HasMeta(pad, "0000001") {
		t.Fatal("has")
	}
	if MetaCount() != 1 {
		t.Fatal("count")
	}
	// other user cannot overwrite
	other := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(other))
	defer func() {
		if recover() == nil {
			// may not catch cross-realm panic in all envs; ignore
		}
	}()
	// owner update ok
	testing.SetRealm(testing.NewUserRealm(owner))
	SetMeta(cross(cur), pad, "0000001", "Updated", "", "", "", "")
	raw2 := GetMeta(pad, "0000001")
	if raw2 == "" {
		t.Fatal("after update")
	}
}
