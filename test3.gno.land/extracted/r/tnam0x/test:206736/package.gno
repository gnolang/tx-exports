package count

import "fmt"

var count int

func Render(path string) string {
	return fmt.Sprintf("Count: %d", count)
}

func Add() {
	count++
}

func Remove() {
	count--
}

import "testing"

func TestCount(t *testing.T) {
	Add()
	Add()
	Add()
	Remove()
	got := Render("")
	expected := "Count: 2"
	if got != expected {
		t.Fatalf("expected %q, got %q.", expected, got)
	}
}
