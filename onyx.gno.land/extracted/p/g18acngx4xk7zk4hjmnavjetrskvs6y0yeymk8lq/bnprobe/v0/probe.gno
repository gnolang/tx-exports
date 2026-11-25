// Package bnprobe is a deployment probe for the bn254 precompiles. It exists so
// a package that imports a crypto stdlib can be submitted and its approval
// status observed; it holds no state and verifies nothing.
package bnprobe

import "crypto/bn254"

// AddInfinity returns the precompile's answer for the identity added to itself.
func AddInfinity() []byte {
	return bn254.G1Add(make([]byte, bn254.G1AddInputSize))
}
