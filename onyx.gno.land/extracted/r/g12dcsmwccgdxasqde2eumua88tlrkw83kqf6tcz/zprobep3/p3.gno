package zprobep3

import "encoding/hex"

func H(b []byte) string { return hex.EncodeToString(b) }
