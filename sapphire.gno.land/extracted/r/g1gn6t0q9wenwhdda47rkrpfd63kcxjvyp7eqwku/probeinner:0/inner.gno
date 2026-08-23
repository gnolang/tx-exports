// Probe: what does a realm see for OriginSend when it is called BY
// another realm, during a transaction where the user attached coins to
// the outer call?
//
// This decides whether a marketplace can transfer a name inside a
// payable Buy(): nslogic's TransferFrom starts with assertNoSend(),
// which panics when OriginSend() is non-zero.
package probeinner

import "chain/runtime/unsafe"

var Last string

func Note(cur realm) string {
	s := unsafe.OriginSend()
	if s.IsZero() {
		Last = "zero"
	} else {
		Last = s.String()
	}
	return Last
}

func Render(path string) string { return Last }
