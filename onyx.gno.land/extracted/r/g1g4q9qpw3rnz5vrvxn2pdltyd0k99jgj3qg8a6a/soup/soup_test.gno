package soup

import (
	"strings"
	"testing"
)

func TestRender(t *testing.T) {
	if s := Render(""); !strings.Contains(s, "version") {
		t.Errorf("home: %s", s)
	}
	s := Render("check/şifrem kartal1907")
	if !strings.Contains(s, "password") || !strings.Contains(s, "| safe | no |") {
		t.Errorf("check: %s", s)
	}
	if strings.Contains(s, "kartal1907") {
		t.Errorf("the checked text must not be echoed")
	}
}
