package authorizable

import (
	"std"
	"testing"

	"gno.land/p/demo/testutils"
	"gno.land/p/demo/uassert"
)

var (
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	charlie = testutils.TestAddress("charlie")
)

func TestNewAuthorizable(t *testing.T) {
	std.TestSetRealm(std.NewUserRealm(alice))
	std.TestSetOriginCaller(alice) // TODO(bug, issue #2371): should not be needed

	a := NewAuthorizable()
	got := a.Owner()

	if alice != got {
		t.Fatalf("Expected %s, got: %s", alice, got)
	}
}

func TestNewAuthorizableWithAddress(t *testing.T) {
	a := NewAuthorizableWithAddress(alice)

	got := a.Owner()

	if alice != got {
		t.Fatalf("Expected %s, got: %s", alice, got)
	}
}

func TestCallerOnAuthList(t *testing.T) {
	a := NewAuthorizableWithAddress(alice)
	std.TestSetRealm(std.NewUserRealm(alice))
	std.TestSetOriginCaller(alice)

	if err := a.CallerOnAuthList(); err == ErrNotInAuthList {
		t.Fatalf("expected alice to be on the list")
	}
}

func TestNotCallerOnAuthList(t *testing.T) {
	a := NewAuthorizableWithAddress(alice)
	std.TestSetRealm(std.NewUserRealm(bob))
	std.TestSetOriginCaller(bob)

	if err := a.CallerOnAuthList(); err == nil {
		t.Fatalf("expected bob to not be on the list")
	}
}

func TestAddToAuthList(t *testing.T) {
	a := NewAuthorizableWithAddress(alice)
	std.TestSetRealm(std.NewUserRealm(alice))
	std.TestSetOriginCaller(alice)

	if err := a.AddToAuthList(bob); err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	std.TestSetRealm(std.NewUserRealm(bob))
	std.TestSetOriginCaller(bob)

	if err := a.AddToAuthList(bob); err == nil {
		t.Fatalf("Expected AddToAuth to error while bob called it, but it didn't")
	}
}

func TestDeleteFromList(t *testing.T) {
	a := NewAuthorizableWithAddress(alice)
	std.TestSetRealm(std.NewUserRealm(alice))
	std.TestSetOriginCaller(alice)

	if err := a.AddToAuthList(bob); err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	if err := a.AddToAuthList(charlie); err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	std.TestSetRealm(std.NewUserRealm(bob))
	std.TestSetOriginCaller(bob)

	// Try an unauthorized deletion
	if err := a.DeleteFromAuthList(alice); err == nil {
		t.Fatalf("Expected DelFromAuth to error with %v", err)
	}

	std.TestSetRealm(std.NewUserRealm(alice))
	std.TestSetOriginCaller(alice)

	if err := a.DeleteFromAuthList(charlie); err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}
}

func TestAssertOnList(t *testing.T) {
	std.TestSetRealm(std.NewUserRealm(alice))
	std.TestSetOriginCaller(alice)
	a := NewAuthorizableWithAddress(alice)

	std.TestSetRealm(std.NewUserRealm(bob))
	std.TestSetOriginCaller(bob)

	uassert.PanicsWithMessage(t, ErrNotInAuthList.Error(), func() {
		a.AssertOnAuthList()
	})
}
