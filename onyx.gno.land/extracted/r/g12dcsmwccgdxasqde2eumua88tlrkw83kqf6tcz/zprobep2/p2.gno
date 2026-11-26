package zprobep2

import "crypto/ed25519"

func V(k, m, s []byte) bool { return ed25519.Verify(k, m, s) }
