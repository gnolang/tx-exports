package gnocialview

import (
	"strings"
	"testing"

	"gno.land/p/nt/urequire/v0"
)

func TestPreparedSheet(t *testing.T) {
	got := Sheet("meta", "", "", "")
	urequire.Equal(t, true, strings.HasPrefix(got, "v1\n2\t"))
}
