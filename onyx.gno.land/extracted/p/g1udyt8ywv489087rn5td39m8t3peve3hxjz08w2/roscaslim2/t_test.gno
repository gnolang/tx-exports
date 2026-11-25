package roscaslim2

import "testing"

func TestValidate(t *testing.T) {
	p := Params{Contribution: 1000000, Collateral: 1000000, Size: 3, RoundSpan: 60}
	if err := p.Validate(); err != nil { t.Fatalf("bad: %v", err) }
}
