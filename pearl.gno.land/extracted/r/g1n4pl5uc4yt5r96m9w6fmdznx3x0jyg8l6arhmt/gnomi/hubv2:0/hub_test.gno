package hubv2

import "testing"

func TestMultiAdminAndModules(cur realm, t *testing.T) {
	resetForTest()
	a1 := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	a2 := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
	testing.SetRealm(testing.NewUserRealm(a1))
	Init(cross(cur))
	if !IsAdmin(a1.String()) {
		t.Fatal("a1 admin")
	}
	if AdminCount() != 1 {
		t.Fatal("count")
	}
	AddAdmin(cross(cur), a2)
	if AdminCount() != 2 {
		t.Fatal("count2")
	}
	pad := "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/gnomi/padv5"
	// a2 can SetModule
	testing.SetRealm(testing.NewUserRealm(a2))
	SetModule(cross(cur), "pad", pad)
	if GetModule("pad") != pad {
		t.Fatal("pad")
	}
	testing.SetRealm(testing.NewUserRealm(a1))
	RemoveAdmin(cross(cur), a2)
	if IsAdmin(a2.String()) {
		t.Fatal("removed")
	}
	lb := ListModules()
	if lb == "" {
		t.Fatal("list")
	}
	if !Inited() {
		t.Fatal("inited")
	}
}
