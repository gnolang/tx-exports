package nft

// Assertion helpers shared by the other _test.gno files of this package.

import (
	"strings"
	"testing"
)

func assert(t *testing.T, ok bool, msg string) {
	t.Helper()
	if !ok {
		t.Fatal(msg)
	}
}

func assertEqual(t *testing.T, got, want, what string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s: got %q, want %q", what, got, want)
	}
}

func assertErrorContains(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected an error containing %q", want)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("error %q does not contain %q", err.Error(), want)
	}
}

func assertContains(t *testing.T, what, got, want string) {
	t.Helper()
	if !strings.Contains(got, want) {
		t.Fatalf("%s: %q does not contain %q", what, got, want)
	}
}

// panicMessage runs fn and returns the text of its panic, or "" if it did not panic.
func panicMessage(fn func()) (message string) {
	defer func() {
		if r := recover(); r != nil {
			message, _ = r.(string)
		}
	}()
	fn()
	return ""
}
