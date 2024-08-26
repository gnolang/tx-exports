package hello

import (
	"testing"

	"gno.land/p/demo/urequire"
)

func TestWorld(t *testing.T) {
	urequire.NotEqual(t, Render(""), "")
}
