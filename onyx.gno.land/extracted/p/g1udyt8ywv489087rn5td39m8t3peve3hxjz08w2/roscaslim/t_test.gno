package roscaslim

import "testing"

func TestGnot(t *testing.T) {
	if Gnot(1500000) != "1.5" { t.Fatalf("bad: %s", Gnot(1500000)) }
}
