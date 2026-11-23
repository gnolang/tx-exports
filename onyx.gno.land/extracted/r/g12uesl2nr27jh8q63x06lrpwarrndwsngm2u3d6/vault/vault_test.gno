package vault

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
)

func TestVault(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))

	fp := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	doc := "invoice-101.pdf"

	res := RegisterInvoice(cross(cur), fp, doc)
	uassert.Equal(t, res, "SUCCESS: registered "+fp)

	if !HasRecord(fp) {
		t.Fatalf("expected HasRecord to be true")
	}

	if GetCount() != 1 {
		t.Fatalf("expected count 1, got %d", GetCount())
	}

	rec := GetRecord(fp)
	if rec == "" {
		t.Fatalf("expected non-empty record")
	}

	rendered := Render("verify/" + fp)
	if rendered == "" {
		t.Fatalf("expected non-empty render")
	}
}
