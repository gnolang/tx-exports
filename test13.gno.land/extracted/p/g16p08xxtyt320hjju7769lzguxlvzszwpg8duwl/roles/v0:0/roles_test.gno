package roles

import "testing"

func TestGrantHasRevoke(t *testing.T) {
	rs := NewRoleSet()
	addr := "g1testaddress000000000000000000000000"
	if rs.Has(addr, "admin") {
		t.Fatal("expected no admin")
	}
	rs.Grant(addr, "admin")
	rs.Grant(addr, "member")
	if !rs.IsAdmin(addr) {
		t.Fatal("expected admin")
	}
	if !rs.Has(addr, "member") {
		t.Fatal("expected member")
	}
	// idempotent
	rs.Grant(addr, "admin")
	roles := rs.List(addr)
	if len(roles) != 2 {
		t.Fatalf("expected 2 roles, got %d", len(roles))
	}
	rs.Revoke(addr, "admin")
	if rs.IsAdmin(addr) {
		t.Fatal("admin should be revoked")
	}
	if !rs.Has(addr, "member") {
		t.Fatal("member should remain")
	}
}
