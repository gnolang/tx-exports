package escrow_v3

import "chain/runtime/unsafe"

// publisherAtLoad captures the AddPackage signer during package initialization.
// Keeping the unsafe load-time primitive separate from crossing entrypoints lets
// privileged calls use only the frame-verified cur.IsCurrent/cur.Previous API.
func publisherAtLoad() address { return unsafe.OriginCaller() }
