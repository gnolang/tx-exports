// Package groth16 implements a general-purpose Groth16 zero-knowledge proof
// verifier over the BN254 pairing-friendly elliptic curve using Gno's native
// crypto/bn254 precompile bindings.
//
// Point and scalar encodings follow EIP-196 / EIP-197:
//   - G1 point: 64 bytes big-endian (x | y), (0, 0) represents infinity.
//   - G2 point: 128 bytes big-endian imaginary-first (x_imag | x_real | y_imag | y_real).
//   - Scalar:   32 bytes big-endian, strictly less than the BN254 scalar field order r.
package groth16

import (
	"crypto/bn254"
	"encoding/hex"
	"errors"
)

const (
	// G1Size is the affine G1 point byte length (x | y).
	G1Size = 64
	// G2Size is the affine G2 point byte length (x_imag | x_real | y_imag | y_real).
	G2Size = 128
	// ScalarSize is the 256-bit scalar byte length.
	ScalarSize = 32
	// ProofSize is the packed proof byte length (A | B | C).
	ProofSize = G1Size + G2Size + G1Size
	// MaxPublicInputs bounds the number of public inputs to prevent unbounded
	// MSM allocation and gas exhaustion on-chain.
	MaxPublicInputs = 64
)

var (
	ErrInvalidVerifyingKey    = errors.New("groth16: invalid verifying key")
	ErrDegenerateVerifyingKey = errors.New("groth16: degenerate zero verifying key point")
	ErrInvalidProof           = errors.New("groth16: invalid proof")
	ErrInvalidInputCount      = errors.New("groth16: public input count mismatch")
	ErrTooManyPublicInputs    = errors.New("groth16: public input count exceeds limit")
	ErrNonCanonicalField      = errors.New("groth16: non-canonical base field element")
	ErrNonCanonicalScalar     = errors.New("groth16: non-canonical scalar field element")
	ErrInvalidCurvePoint      = errors.New("groth16: invalid curve or subgroup point")
	ErrInvalidEncoding        = errors.New("groth16: invalid hex or byte encoding")
	ErrVerificationFailed     = errors.New("groth16: pairing verification failed")
)

// BN254 base field prime p = 21888242871839275222246405745257275088696311157297823662689037894645226208583.
var bn254BaseFieldP = [32]byte{
	0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
	0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
	0x97, 0x81, 0x6a, 0x91, 0x68, 0x71, 0xca, 0x8d,
	0x3c, 0x20, 0x8c, 0x16, 0xd8, 0x7c, 0xfd, 0x47,
}

// BN254 scalar field order r = 21888242871839275222246405745257275088548364400416034343698204186575808495617.
var bn254ScalarFieldR = [32]byte{
	0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
	0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
	0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
	0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
}

// VerifyingKey holds the circuit-specific Groth16 verification key.
type VerifyingKey struct {
	Alpha []byte   // 64 bytes G1
	Beta  []byte   // 128 bytes G2 (imag-first)
	Gamma []byte   // 128 bytes G2 (imag-first)
	Delta []byte   // 128 bytes G2 (imag-first)
	IC    [][]byte // len(IC) == len(publicInputs) + 1, each 64 bytes G1
}

// Proof holds a Groth16 proof (A in G1, B in G2, C in G1).
type Proof struct {
	A []byte // 64 bytes G1
	B []byte // 128 bytes G2 (imag-first)
	C []byte // 64 bytes G1
}

// Verify checks a Groth16 proof against a VerifyingKey and public inputs.
// Returns nil iff the proof is valid.
func Verify(vk VerifyingKey, proof Proof, publicInputs [][]byte) error {
	if err := validateVerifyingKey(vk); err != nil {
		return err
	}
	if len(publicInputs) != len(vk.IC)-1 {
		return ErrInvalidInputCount
	}
	if err := validateG1Coords(proof.A); err != nil {
		return err
	}
	if err := validateG2Coords(proof.B); err != nil {
		return err
	}
	if err := validateG1Coords(proof.C); err != nil {
		return err
	}
	for i := 0; i < len(publicInputs); i++ {
		if err := validateScalar(publicInputs[i]); err != nil {
			return err
		}
	}

	// Compute vk_x = IC[0] + sum_{i=0..n-1} publicInputs[i] * IC[i+1].
	vkX := make([]byte, G1Size)
	copy(vkX, vk.IC[0])

	for i := 0; i < len(publicInputs); i++ {
		mulBuf := make([]byte, bn254.G1MulInputSize)
		copy(mulBuf[0:G1Size], vk.IC[i+1])
		copy(mulBuf[G1Size:bn254.G1MulInputSize], publicInputs[i])
		term := bn254.G1Mul(mulBuf)
		if len(term) != bn254.G1OutputSize {
			return ErrInvalidCurvePoint
		}

		addBuf := make([]byte, bn254.G1AddInputSize)
		copy(addBuf[0:G1Size], vkX)
		copy(addBuf[G1Size:bn254.G1AddInputSize], term)
		sum := bn254.G1Add(addBuf)
		if len(sum) != bn254.G1OutputSize {
			return ErrInvalidCurvePoint
		}
		vkX = sum
	}

	// Negate G1 points so we can check:
	// e(A, B) * e(-Alpha, Beta) * e(-vkX, Gamma) * e(-C, Delta) == 1.
	negAlpha, err := negateG1(vk.Alpha)
	if err != nil {
		return err
	}
	negVkX, err := negateG1(vkX)
	if err != nil {
		return err
	}
	negC, err := negateG1(proof.C)
	if err != nil {
		return err
	}

	pairingInput := make([]byte, 0, 4*bn254.PairingChunkSize)
	pairingInput = append(pairingInput, proof.A...)
	pairingInput = append(pairingInput, proof.B...)
	pairingInput = append(pairingInput, negAlpha...)
	pairingInput = append(pairingInput, vk.Beta...)
	pairingInput = append(pairingInput, negVkX...)
	pairingInput = append(pairingInput, vk.Gamma...)
	pairingInput = append(pairingInput, negC...)
	pairingInput = append(pairingInput, vk.Delta...)

	out := bn254.PairingCheck(pairingInput)
	if len(out) != bn254.PairingOutputSize {
		return ErrInvalidCurvePoint
	}
	for i := 0; i < 31; i++ {
		if out[i] != 0 {
			return ErrVerificationFailed
		}
	}
	if out[31] != 1 {
		return ErrVerificationFailed
	}
	return nil
}

// VerifyBytes parses a packed 256-byte proof (A | B | C) and verifies it.
func VerifyBytes(vk VerifyingKey, proofBytes []byte, publicInputs [][]byte) error {
	proof, err := ParseProofBytes(proofBytes)
	if err != nil {
		return err
	}
	return Verify(vk, proof, publicInputs)
}

// ParseProofBytes parses a 256-byte packed proof (A(64) | B(128) | C(64)).
func ParseProofBytes(b []byte) (Proof, error) {
	if len(b) != ProofSize {
		return Proof{}, ErrInvalidEncoding
	}
	a := make([]byte, G1Size)
	copy(a, b[0:G1Size])
	bPt := make([]byte, G2Size)
	copy(bPt, b[G1Size:G1Size+G2Size])
	c := make([]byte, G1Size)
	copy(c, b[G1Size+G2Size:ProofSize])
	return Proof{A: a, B: bPt, C: c}, nil
}

// ParseProofHex decodes hex-encoded proof components into a Proof.
func ParseProofHex(aHex, bHex, cHex string) (Proof, error) {
	a, err := decodeExactHex(aHex, G1Size)
	if err != nil {
		return Proof{}, err
	}
	bPt, err := decodeExactHex(bHex, G2Size)
	if err != nil {
		return Proof{}, err
	}
	c, err := decodeExactHex(cHex, G1Size)
	if err != nil {
		return Proof{}, err
	}
	return Proof{A: a, B: bPt, C: c}, nil
}

// ParseVerifyingKeyHex decodes hex-encoded verification key components.
func ParseVerifyingKeyHex(alphaHex, betaHex, gammaHex, deltaHex string, icHex []string) (VerifyingKey, error) {
	if len(icHex) == 0 {
		return VerifyingKey{}, ErrInvalidVerifyingKey
	}
	if len(icHex) > MaxPublicInputs+1 {
		return VerifyingKey{}, ErrTooManyPublicInputs
	}
	alpha, err := decodeExactHex(alphaHex, G1Size)
	if err != nil {
		return VerifyingKey{}, err
	}
	beta, err := decodeExactHex(betaHex, G2Size)
	if err != nil {
		return VerifyingKey{}, err
	}
	gamma, err := decodeExactHex(gammaHex, G2Size)
	if err != nil {
		return VerifyingKey{}, err
	}
	delta, err := decodeExactHex(deltaHex, G2Size)
	if err != nil {
		return VerifyingKey{}, err
	}
	ic := make([][]byte, len(icHex))
	for i := 0; i < len(icHex); i++ {
		pt, err := decodeExactHex(icHex[i], G1Size)
		if err != nil {
			return VerifyingKey{}, err
		}
		ic[i] = pt
	}
	return VerifyingKey{
		Alpha: alpha,
		Beta:  beta,
		Gamma: gamma,
		Delta: delta,
		IC:    ic,
	}, nil
}

// ParsePublicInputsHex decodes hex-encoded 32-byte scalars.
func ParsePublicInputsHex(inputsHex []string) ([][]byte, error) {
	if len(inputsHex) > MaxPublicInputs {
		return nil, ErrTooManyPublicInputs
	}
	out := make([][]byte, len(inputsHex))
	for i := 0; i < len(inputsHex); i++ {
		b, err := decodeExactHex(inputsHex[i], ScalarSize)
		if err != nil {
			return nil, err
		}
		out[i] = b
	}
	return out, nil
}

// EncodeProofBytes serializes a Proof into its packed 256-byte (A | B | C) form.
func EncodeProofBytes(p Proof) ([]byte, error) {
	if len(p.A) != G1Size || len(p.B) != G2Size || len(p.C) != G1Size {
		return nil, ErrInvalidEncoding
	}
	out := make([]byte, ProofSize)
	copy(out[0:G1Size], p.A)
	copy(out[G1Size:G1Size+G2Size], p.B)
	copy(out[G1Size+G2Size:ProofSize], p.C)
	return out, nil
}

func validateVerifyingKey(vk VerifyingKey) error {
	if len(vk.IC) == 0 {
		return ErrInvalidVerifyingKey
	}
	if len(vk.IC) > MaxPublicInputs+1 {
		return ErrTooManyPublicInputs
	}
	if err := validateG1Coords(vk.Alpha); err != nil {
		return err
	}
	if isZeroSlice(vk.Alpha) {
		return ErrDegenerateVerifyingKey
	}
	if err := validateG2Coords(vk.Beta); err != nil {
		return err
	}
	if isZeroSlice(vk.Beta) {
		return ErrDegenerateVerifyingKey
	}
	if err := validateG2Coords(vk.Gamma); err != nil {
		return err
	}
	if isZeroSlice(vk.Gamma) {
		return ErrDegenerateVerifyingKey
	}
	if err := validateG2Coords(vk.Delta); err != nil {
		return err
	}
	if isZeroSlice(vk.Delta) {
		return ErrDegenerateVerifyingKey
	}
	for i := 0; i < len(vk.IC); i++ {
		if err := validateG1Coords(vk.IC[i]); err != nil {
			return err
		}
	}
	return nil
}

func validateG1Coords(p []byte) error {
	if len(p) != G1Size {
		return ErrInvalidEncoding
	}
	if compareBE32(p[0:32], bn254BaseFieldP[:]) >= 0 {
		return ErrNonCanonicalField
	}
	if compareBE32(p[32:64], bn254BaseFieldP[:]) >= 0 {
		return ErrNonCanonicalField
	}
	return nil
}

func validateG2Coords(p []byte) error {
	if len(p) != G2Size {
		return ErrInvalidEncoding
	}
	for off := 0; off < G2Size; off += 32 {
		if compareBE32(p[off:off+32], bn254BaseFieldP[:]) >= 0 {
			return ErrNonCanonicalField
		}
	}
	return nil
}

func validateScalar(s []byte) error {
	if len(s) != ScalarSize {
		return ErrInvalidEncoding
	}
	if compareBE32(s, bn254ScalarFieldR[:]) >= 0 {
		return ErrNonCanonicalScalar
	}
	return nil
}

func negateG1(p []byte) ([]byte, error) {
	if err := validateG1Coords(p); err != nil {
		return nil, err
	}
	out := make([]byte, G1Size)
	copy(out[0:32], p[0:32])
	if isZero32(p[0:32]) && isZero32(p[32:64]) {
		return out, nil
	}
	if isZero32(p[32:64]) {
		return out, nil
	}
	negY := subBE32(bn254BaseFieldP[:], p[32:64])
	copy(out[32:64], negY)
	return out, nil
}

func decodeExactHex(s string, expectedBytes int) ([]byte, error) {
	if len(s) >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		s = s[2:]
	}
	if len(s) != expectedBytes*2 {
		return nil, ErrInvalidEncoding
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil, ErrInvalidEncoding
	}
	return b, nil
}

func compareBE32(a, b []byte) int {
	for i := 0; i < 32; i++ {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	return 0
}

func isZero32(a []byte) bool {
	for i := 0; i < 32; i++ {
		if a[i] != 0 {
			return false
		}
	}
	return true
}

func isZeroSlice(a []byte) bool {
	for i := 0; i < len(a); i++ {
		if a[i] != 0 {
			return false
		}
	}
	return true
}

func subBE32(a, b []byte) []byte {
	out := make([]byte, 32)
	var borrow uint16
	for i := 31; i >= 0; i-- {
		diff := int(a[i]) - int(b[i]) - int(borrow)
		if diff < 0 {
			diff += 256
			borrow = 1
		} else {
			borrow = 0
		}
		out[i] = byte(diff)
	}
	return out
}
