package demo

import "testing"

func Test(t *testing.T) {
	got := Hello()
	expected := "Hello World!"
	if got != expected {
		t.Fatalf("expected %q, got %q.", expected, got)
	}

	got2 := privateMethod()
	expected2 := "I'm private"
	if got2 != expected2 {
		t.Fatalf("expected %q, got %q.", expected2, got2)
	}
}
