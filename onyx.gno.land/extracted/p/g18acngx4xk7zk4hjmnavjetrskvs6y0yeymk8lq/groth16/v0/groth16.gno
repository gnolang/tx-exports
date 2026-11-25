// Package groth16 verifies Groth16 zkSNARK proofs on BN254 using the chain's
// native precompiles, with no trusted off-chain verifier in the path.
//
// The standard Groth16 verification equation is
//
//	e(A, B) == e(alpha, beta) * e(vk_x, gamma) * e(C, delta)
//
// and it is checked as one four-pair product equal to the identity in GT:
//
//	e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1
//
// Verifying keys and proofs use the encodings the precompiles consume: G1 is
// x|y (64 bytes), G2 is x_imag|x_real|y_imag|y_real (128 bytes, EIP-197
// order), scalars are 32 bytes big-endian. Those are the shapes snarkjs and
// circom emit after the conversion performed by this repo's CLI.
//
// Cost and limits a caller must know:
//   - Verification is four pairings plus one G1 scalar multiplication per
//     public input. Cost does not grow with circuit size, only with the number
//     of public inputs.
//   - A is negated with a scalar multiplication by r-1 instead of subtracting
//     its y coordinate from the field modulus. Subtracting by hand would be a
//     second implementation of field arithmetic, with its own bugs.
//   - The precompile reduces scalars modulo the group order, so two different
//     32-byte encodings of the same scalar verify identically. This changes no
//     accepted proof, and it means callers must not treat an accepted public
//     input's bytes as canonical.
package groth16

import (
	"crypto/bn254"
	"encoding/hex"
	"errors"
)

const (
	// g1Size is the precompile's G1 encoding: x|y, 32 bytes each.
	g1Size = 64
	// g2Size is the precompile's G2 encoding: x_imag|x_real|y_imag|y_real.
	g2Size = 128
	// scalarSize is one scalar field element, big-endian.
	scalarSize = 32
	// pairingChunkSize is one (G1, G2) factor as the pairing precompile reads
	// it: the 64-byte G1 point followed by the 128-byte G2 point (EIP-197).
	pairingChunkSize = g1Size + g2Size
	// pairingWordSize is the length of the pairing precompile's boolean answer.
	pairingWordSize = 32
)

// G1 is a point on the BN254 G1 curve in the precompile's 64-byte encoding.
type G1 [g1Size]byte

// G2 is a point on the BN254 G2 curve in the precompile's 128-byte encoding.
type G2 [g2Size]byte

// Scalar is a public input field element in the scalar field, big-endian.
type Scalar [scalarSize]byte

// VerifyingKey holds the circuit-specific verification parameters. IC holds
// len(publicInputs)+1 points: IC[0] is the constant term and IC[i+1] is the
// base for public input i.
type VerifyingKey struct {
	Alpha G1
	Beta  G2
	Gamma G2
	Delta G2
	IC    []G1
}

// Proof is a Groth16 proof: two G1 points and one G2 point.
type Proof struct {
	A G1
	B G2
	C G1
}

var (
	// ErrInvalidProof means the proof is well formed and false.
	ErrInvalidProof = errors.New("groth16: proof does not verify")
	// ErrPublicInputs means the input count does not match the key.
	ErrPublicInputs = errors.New("groth16: public input count does not match verifying key")
	// ErrMalformedKey means the verifying key contains a point the precompile
	// rejects, or a degenerate point that would let the pairing product equal
	// one for the wrong reason.
	ErrMalformedKey = errors.New("groth16: malformed verifying key")
	// ErrMalformedProof means a proof point is rejected by the precompile or is
	// the point at infinity, which no valid Groth16 proof contains.
	ErrMalformedProof = errors.New("groth16: malformed proof")
)

// negateScalarHex is r-1 in the BN254 scalar field, big-endian, where
// r = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001.
// Multiplying a G1 point by it yields the point's negation.
const negateScalarHex = "30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000"

// minusOne is decoded once at init. The value is a hard-coded constant, so a
// decode failure is a build defect rather than runtime input.
var minusOne = mustScalar(negateScalarHex)

// Verify reports whether proof is valid for vk and the given public inputs.
//
// It returns ErrPublicInputs when len(inputs) != len(vk.IC)-1, ErrMalformedKey
// or ErrMalformedProof when a point is not acceptable to the precompiles or is
// the point at infinity, and ErrInvalidProof when the equation does not hold.
func Verify(vk VerifyingKey, proof Proof, inputs []Scalar) error {
	if len(vk.IC) == 0 || len(inputs) != len(vk.IC)-1 {
		return ErrPublicInputs
	}
	if err := vk.validate(); err != nil {
		return err
	}
	if err := proof.validate(); err != nil {
		return err
	}

	vkx, err := linearCombination(vk.IC, inputs)
	if err != nil {
		return err
	}
	negA, err := negate(proof.A)
	if err != nil {
		return err
	}

	equation := []pairing{
		{g1: negA, g2: proof.B},
		{g1: vk.Alpha, g2: vk.Beta},
		{g1: vkx, g2: vk.Gamma},
		{g1: proof.C, g2: vk.Delta},
	}
	if !pairingIsOne(equation) {
		return ErrInvalidProof
	}
	return nil
}

// validate rejects keys that could make the pairing product equal one for a
// degenerate reason. With every term at infinity the product is one and a zero
// proof would pass, which is why infinity is refused here rather than left to
// the pairing check.
func (vk VerifyingKey) validate() error {
	if isInfinityG1(vk.Alpha) || isInfinityG2(vk.Beta) ||
		isInfinityG2(vk.Gamma) || isInfinityG2(vk.Delta) {
		return ErrMalformedKey
	}
	// A well-formed key still has to be accepted by the precompiles, which is
	// only observable by using it. Adding IC[0] to the identity is the cheapest
	// use that both validates the point and leaves the accumulator unchanged.
	if _, err := add(vk.IC[0], G1{}); err != nil {
		return ErrMalformedKey
	}
	return nil
}

// validate refuses infinity in every proof component. A valid Groth16 proof is
// built from non-zero scalars, so no component is ever the identity.
func (p Proof) validate() error {
	if isInfinityG1(p.A) || isInfinityG2(p.B) || isInfinityG1(p.C) {
		return ErrMalformedProof
	}
	if err := probeG1(p.A); err != nil {
		return ErrMalformedProof
	}
	return nil
}

// linearCombination computes IC[0] + sum(inputs[i] * IC[i+1]).
func linearCombination(ic []G1, inputs []Scalar) (G1, error) {
	acc := ic[0]
	for i := 0; i < len(inputs); i++ {
		term, err := scalarMul(ic[i+1], inputs[i])
		if err != nil {
			return G1{}, ErrMalformedKey
		}
		acc, err = add(acc, term)
		if err != nil {
			return G1{}, ErrMalformedKey
		}
	}
	return acc, nil
}

// pairing is one (G1, G2) factor of the product being checked.
type pairing struct {
	g1 G1
	g2 G2
}

// pairingTrue is the pairing precompile's success answer: one 32-byte word whose
// last byte is 1 and whose other 31 bytes are zero.
var pairingTrue = [pairingWordSize]byte{pairingWordSize - 1: 1}

// pairingIsOne reports whether the product of the given factors equals the
// identity in GT. A short or nil answer means the precompile rejected an input
// point, which is not the identity and therefore not a pass.
func pairingIsOne(factors []pairing) bool {
	out := bn254.PairingCheck(encodePairingInput(factors))
	if len(out) != pairingWordSize {
		return false
	}
	var got [pairingWordSize]byte
	copy(got[:], out)
	return got == pairingTrue
}

// encodePairingInput lays the factors out as the precompile reads them: for each
// factor, the 64-byte G1 point then the 128-byte G2 point, in the given order.
func encodePairingInput(factors []pairing) []byte {
	in := make([]byte, len(factors)*pairingChunkSize)
	for i, f := range factors {
		off := i * pairingChunkSize
		copy(in[off:off+g1Size], f.g1[:])
		copy(in[off+g1Size:off+pairingChunkSize], f.g2[:])
	}
	return in
}

// negate returns -p by multiplying by r-1.
func negate(p G1) (G1, error) {
	return scalarMul(p, minusOne)
}

// add returns p+q. It reports ErrMalformedKey when the precompile rejects
// either point; the proof path remaps that to ErrMalformedProof at its boundary.
func add(p, q G1) (G1, error) {
	in := make([]byte, 0, bn254.G1AddInputSize)
	in = append(in, p[:]...)
	in = append(in, q[:]...)
	return decodeG1(bn254.G1Add(in))
}

// scalarMul returns s*p.
func scalarMul(p G1, s Scalar) (G1, error) {
	in := make([]byte, 0, bn254.G1MulInputSize)
	in = append(in, p[:]...)
	in = append(in, s[:]...)
	return decodeG1(bn254.G1Mul(in))
}

// decodeG1 copies a G1-sized precompile result into the fixed encoding. The
// precompiles answer with nil rather than with an error, so a length other than
// g1Size is the only signal that a point or scalar was rejected.
func decodeG1(out []byte) (G1, error) {
	if len(out) != g1Size {
		return G1{}, ErrMalformedKey
	}
	var p G1
	copy(p[:], out)
	return p, nil
}

// probeG1 makes the precompiles validate a point without changing it.
func probeG1(p G1) error {
	_, err := add(p, G1{})
	return err
}

// isInfinityG1 reports whether p is the all-zero encoding, which the
// precompiles read as the point at infinity.
func isInfinityG1(p G1) bool {
	for i := 0; i < len(p); i++ {
		if p[i] != 0 {
			return false
		}
	}
	return true
}

// isInfinityG2 reports whether p is the all-zero encoding of G2 infinity.
func isInfinityG2(p G2) bool {
	for i := 0; i < len(p); i++ {
		if p[i] != 0 {
			return false
		}
	}
	return true
}

// mustScalar decodes a 32-byte big-endian constant.
func mustScalar(s string) Scalar {
	raw, err := hex.DecodeString(s)
	if err != nil || len(raw) != scalarSize {
		panic("groth16: bad scalar constant")
	}
	var out Scalar
	copy(out[:], raw)
	return out
}
