package hello

import (
    "std"
    "testing"
)

func TestPackage(t *testing.T) {
    got := Render("")
    expected := "8835537047539158391"

    if (got != expected) {
        t.Errorf("expected %q; got %q", expected, got)
    }
}