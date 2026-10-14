package enckeys_v1

import "chain/runtime/unsafe"

// Only reached after the direct, frame-checked caller guard. Kept separate
// from crossing entrypoints so payment-envelope use is easy to audit.
func assertNoCoins() {
	if !unsafe.OriginSend().IsZero() {
		panic("enckeys: no coins")
	}
}
