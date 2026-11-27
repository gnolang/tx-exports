package soup

import (
	"strings"
	"testing"
)

func TestRender(t *testing.T) {
	home := Render("")
	for _, want := range []string{"version", "<gno-form", "gno-columns", "data:image/svg+xml"} {
		if !strings.Contains(home, want) {
			t.Errorf("home misses %q", want)
		}
	}
	s := Render("check?text=" + "%C5%9Fifrem+kartal1907")
	if !strings.Contains(s, "password") || !strings.Contains(s, "Blocked") {
		t.Errorf("form check: %s", s)
	}
	if strings.Contains(s, "kartal1907") {
		t.Errorf("the checked text must not be echoed")
	}
	s = Render("check/my%20password%20is%20eagle1907")
	if !strings.Contains(s, "Blocked") {
		t.Errorf("link check: %s", s)
	}
	s = Render("check?text=I+forgot+my+password+again")
	if !strings.Contains(s, "Safe to store") {
		t.Errorf("safe check: %s", s)
	}
	if !strings.Contains(Render("check?text="), "Type a message") {
		t.Errorf("empty check")
	}
}
