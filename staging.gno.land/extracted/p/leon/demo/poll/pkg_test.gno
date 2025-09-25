package poll

import "testing"

func TestNewPoll(t *testing.T) {
	title := "My Poll"
	desc := "This is my first poll"
	deadline := 1000

	p := NewPoll(title, desc, deadline)

	if p.title != "My Poll" {
		t.Fatalf("expected %s, got %s", title, p.title)
	}
}
