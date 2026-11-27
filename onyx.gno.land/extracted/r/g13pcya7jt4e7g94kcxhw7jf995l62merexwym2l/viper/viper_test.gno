package viper

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestPlan(t *testing.T) {
	p := Plan("seed-1")
	uassert.Equal(t, 3, len(p))
	uassert.Equal(t, p, Plan("seed-1"))
	s, _, _ := Weights()
	uassert.Equal(t, 6, s)
	uassert.True(t, strings.Contains(Render(""), "Viper"))
}
