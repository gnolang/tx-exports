package mymood

import "testing"

func TestRender(t *testing.T) {
	// Arrange
	want := "curious"

	// Act
	got := Render("")

	// Assert
	if got != want {
		t.Fatalf("expected output: '%s', got: '%s'", want, got)
	}
}

func TestChangeMyMood(t *testing.T) {
	// Arrange
	wantRender := "My current mood is curious"
	wantOutput := "Mood succesfully updated"

	// Act
	got := ChangeMyMood("curious")

	// Assert
	if got != wantOutput {
		t.Fatalf("expected output: '%s', got: '%s'", wantOutput, got)
	}

	if got := Render(""); got != wantRender {
		t.Fatalf("expected render outout: '%s', got: '%s'", wantRender, got)
	}
}
