package profile

import "testing"

func TestSetGetProfile(cur realm, t *testing.T) {
	resetForTest()
	user := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(user))
	Init(cross(cur))
	SetProfile(cross(cur), "Alice", "builder on gno", "https://example.com")
	raw := GetProfile(user.String())
	if raw == "" {
		t.Fatal("empty profile")
	}
	if !HasProfile(user.String()) {
		t.Fatal("has")
	}
	if ProfileCount() != 1 {
		t.Fatal("count")
	}
	r := Render("user/" + user.String())
	if r == "" {
		t.Fatal("render")
	}
	ClearProfile(cross(cur))
	if HasProfile(user.String()) {
		t.Fatal("not cleared")
	}
}
