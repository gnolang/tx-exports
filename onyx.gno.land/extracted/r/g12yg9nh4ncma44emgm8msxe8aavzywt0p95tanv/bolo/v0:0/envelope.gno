package bolo

import "chain/runtime/unsafe"

// envelopeUgnot returns the ugnot attached to this call (API C3, C4): an envelope is
// one ugnot coin, or nothing; anything else is ErrWrongDenom. It is the one place
// Bolo reads OriginSend, and only user-only writes reach it: C11's keyed refusal, then
// AssertOriginCall, in their own body (make check). Never a write behind C11's realm
// branch, which a deployed realm passes with an envelope paid to itself.
func envelopeUgnot() int64 {
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		return 0
	}
	if len(sent) > 1 || sent[0].Denom != "ugnot" {
		panic(ErrWrongDenom)
	}
	return sent[0].Amount
}
