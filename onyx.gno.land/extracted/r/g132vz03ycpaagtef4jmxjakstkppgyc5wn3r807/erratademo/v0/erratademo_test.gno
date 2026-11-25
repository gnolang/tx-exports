package erratademo

import (
	"strings"
	"testing"

	"gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v0"
)

func TestEmbedAcceptedErrata(cur realm, t *testing.T) {
	if BookID() != 0 || !strings.Contains(Render(""), "No errata yet.") {
		t.Fatal("an unlinked guide should render its empty state")
	}
	// The unit-test loader has no deployment transaction or creator.
	owner = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	reader := address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	testing.SetRealm(testing.NewUserRealm(owner))
	id := erratabank.CreateBook(cross(cur), "Quickstart", "First", "https://example.org/guide", 0)
	testing.SetRealm(testing.NewUserRealm(reader))
	reportID := erratabank.Submit(cross(cur), id, "Section 1", "Use the new endpoint.")
	if got := revive(func() { SetBook(cross(cur), id) }); got != "demo deployer only" {
		t.Fatalf("unexpected unauthorized result: %v", got)
	}

	testing.SetRealm(testing.NewUserRealm(owner))
	if got := revive(func() { SetBook(cross(cur), 0) }); got != "book not found" {
		t.Fatalf("unexpected missing book result: %v", got)
	}
	SetBook(cross(cur), id)
	if got := revive(func() { SetBook(cross(cur), id) }); got != "demo book already set" {
		t.Fatalf("unexpected second link result: %v", got)
	}
	if BookID() != id || strings.Contains(Render(""), "Use the new endpoint") {
		t.Fatal("pending reports should stay out of the embedded section")
	}

	erratabank.Accept(cross(cur), reportID, "Confirmed")
	rendered := Render("")
	if !strings.Contains(rendered, "## Errata") || !strings.Contains(rendered, "Use the new endpoint") {
		t.Fatalf("accepted correction missing from guide: %s", rendered)
	}
	if got := Render("?page=2"); !strings.Contains(got, "Errata page not found.") {
		t.Fatalf("unexpected out-of-range page: %s", got)
	}
}
