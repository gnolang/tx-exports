package hello

import "testing"

func TestVisit(cur realm, t *testing.T) {
	visits = 0
	if got := Visit(cross(cur)); got != 1 {
		t.Fatalf("Visit() = %d, want 1", got)
	}
	if got := Render(""); got != "# Hello, Gnome Tavern\n\nVisits: 1" {
		t.Fatalf("Render() = %q", got)
	}
}
