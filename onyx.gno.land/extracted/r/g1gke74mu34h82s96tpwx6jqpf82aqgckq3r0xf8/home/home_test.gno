package home

import "testing"

func TestRenderRoot(t *testing.T) {
	out := Render("")
	if out == "" {
		t.Fatal("Render(\"\") returned empty markdown")
	}
	t.Log("Render(\"\") output:\n" + out)
}

func TestRenderSubpage(t *testing.T) {
	if Render("somepath") == "" {
		t.Fatal("Render(subpath) returned empty markdown")
	}
}
