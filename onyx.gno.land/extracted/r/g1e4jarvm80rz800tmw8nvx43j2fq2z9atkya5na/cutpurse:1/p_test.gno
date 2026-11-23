package cutpurse

import "testing"

const u = "/r/REPLACE_WITH_DEPLOY_ADDRESS/cutpurse:job/8/g1qrmldr7hh985wngaklzfkzlt588z4gewtlgwg0"

func TestP1(t *testing.T) {
	seed()
	for i := 0; i < 10; i++ {
		_ = attr(u)
	}
}
func TestP2(t *testing.T) {
	seed()
	for i := 0; i < 10; i++ {
		_ = self("job/8")
	}
}
func TestP3(t *testing.T) {
	seed()
	for i := 0; i < 10; i++ {
		_ = md("a", u)
	}
}
func TestP4(t *testing.T) {
	seed()
	for i := 0; i < 10; i++ {
		_ = money(123456)
	}
}
func TestP5(t *testing.T) {
	seed()
	for i := 0; i < 10; i++ {
		_ = who("g1qrmldr7hh985wngaklzfkzlt588z4gewtlgwg0")
	}
}
