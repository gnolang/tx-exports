package ironclad

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestPlan(t *testing.T) {
	p := Plan("seed-1")
	uassert.Equal(t, 3, len(p))
	uassert.Equal(t, p, Plan("seed-1")) // deterministic
	for _, c := range p {
		uassert.True(t, strings.ContainsRune("SGF", c))
	}
	_, g, _ := Weights()
	uassert.Equal(t, 6, g)
	uassert.True(t, strings.Contains(Render(""), "Ironclad"))
}
