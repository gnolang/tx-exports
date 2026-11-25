package groth16

import (
	"crypto/bn254"
	"encoding/hex"
	"testing"
)

// The G1 generator is (1, 2). The G2 generator below is the value the
// precompiles accept in EIP-197 order, taken from the chain's own bn254 test
// vectors (case "one_point").
const (
	g1GeneratorHex = "0000000000000000000000000000000000000000000000000000000000000001" +
		"0000000000000000000000000000000000000000000000000000000000000002"
	g2GeneratorHex = "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" +
		"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" +
		"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" +
		"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
)

func g1Generator(t *testing.T) G1 {
	t.Helper()
	var p G1
	raw, err := hex.DecodeString(g1GeneratorHex)
	if err != nil || len(raw) != g1Size {
		t.Fatalf("bad g1 constant: %v", err)
	}
	copy(p[:], raw)
	return p
}

func g2Generator(t *testing.T) G2 {
	t.Helper()
	var p G2
	raw, err := hex.DecodeString(g2GeneratorHex)
	if err != nil || len(raw) != g2Size {
		t.Fatalf("bad g2 constant: %v", err)
	}
	copy(p[:], raw)
	return p
}

// TestPrecompileSizesMatch pins the local layout constants to the precompile's
// own, so a chain-side change cannot silently reinterpret the buffer.
func TestPrecompileSizesMatch(t *testing.T) {
	if pairingChunkSize != bn254.PairingChunkSize {
		t.Fatalf("chunk size %d, precompile reads %d", pairingChunkSize, bn254.PairingChunkSize)
	}
	if pairingWordSize != bn254.PairingOutputSize {
		t.Fatalf("word size %d, precompile answers %d", pairingWordSize, bn254.PairingOutputSize)
	}
}

// TestG2GeneratorEncodingIsAccepted is the layout test. If the G2 constants
// were in the wrong field order the point would fail the curve check and the
// precompile would answer nil instead of a 32-byte word.
func TestG2GeneratorEncodingIsAccepted(t *testing.T) {
	pair := pairing{g1: g1Generator(t), g2: g2Generator(t)}
	if pairingIsOne([]pairing{pair}) {
		t.Fatal("a single pairing must not equal the identity")
	}
}

// TestNegateIsInverse is the check that replaces a hand-written field
// subtraction: p + (-p) is the identity, which the precompiles encode as 64
// zero bytes.
func TestNegateIsInverse(t *testing.T) {
	g := g1Generator(t)
	neg, err := negate(g)
	if err != nil {
		t.Fatalf("negate: %v", err)
	}
	sum, err := add(g, neg)
	if err != nil {
		t.Fatalf("add: %v", err)
	}
	if !isInfinityG1(sum) {
		t.Fatalf("p + (-p) is not the identity: %x", sum[:])
	}
	if isInfinityG1(neg) {
		t.Fatal("negation of the generator is the identity")
	}
}

// TestPairingProductOfInverseIsOne runs the four-pair shape the verifier uses:
// e(p, q) * e(-p, q) == 1.
func TestPairingProductOfInverseIsOne(t *testing.T) {
	g1 := g1Generator(t)
	g2 := g2Generator(t)
	neg, err := negate(g1)
	if err != nil {
		t.Fatalf("negate: %v", err)
	}
	product := []pairing{{g1: g1, g2: g2}, {g1: neg, g2: g2}}
	if !pairingIsOne(product) {
		t.Fatal("e(p, q) * e(-p, q) did not equal one")
	}
}

// testVK returns a well-formed key with one public input slot. Every point is a
// real generator, so key validation passes and a test can isolate the failure it
// is actually about.
func testVK(t *testing.T) VerifyingKey {
	t.Helper()
	g := g1Generator(t)
	g2 := g2Generator(t)
	return VerifyingKey{Alpha: g, Beta: g2, Gamma: g2, Delta: g2, IC: []G1{g, g}}
}

// TestVerifyRejectsInputCountMismatch pins that the count check runs before any
// point is touched: a key with one public input slot and zero inputs is a count
// error, not a key error.
func TestVerifyRejectsInputCountMismatch(t *testing.T) {
	vk := testVK(t)
	proof := Proof{A: g1Generator(t), B: g2Generator(t), C: g1Generator(t)}

	if err := Verify(vk, proof, nil); err != ErrPublicInputs {
		t.Fatalf("too few inputs: want ErrPublicInputs, got %v", err)
	}
	if err := Verify(vk, proof, []Scalar{{}, {}}); err != ErrPublicInputs {
		t.Fatalf("too many inputs: want ErrPublicInputs, got %v", err)
	}
	if err := Verify(VerifyingKey{}, proof, nil); err != ErrPublicInputs {
		t.Fatalf("empty key: want ErrPublicInputs, got %v", err)
	}
}

// TestVerifyRejectsDegenerateKey covers the case a plain pairing check misses:
// with every key point at infinity the product is one, so a zero proof would be
// accepted. The key validation has to reject it first.
func TestVerifyRejectsDegenerateKey(t *testing.T) {
	err := Verify(VerifyingKey{IC: []G1{{}}}, Proof{}, nil)
	if err != ErrMalformedKey {
		t.Fatalf("want ErrMalformedKey, got %v", err)
	}
}

func TestVerifyRejectsInfinityInProof(t *testing.T) {
	g1 := g1Generator(t)
	g2 := g2Generator(t)
	vk := VerifyingKey{Alpha: g1, Beta: g2, Gamma: g2, Delta: g2, IC: []G1{g1}}
	err := Verify(vk, Proof{A: g1, B: g2}, nil)
	if err != ErrMalformedProof {
		t.Fatalf("want ErrMalformedProof for a proof with C at infinity, got %v", err)
	}
}

// TestVerifyRejectsOffCurveKeyPoint pins that a point the precompile refuses is
// reported as a key defect, not as a false proof.
func TestVerifyRejectsOffCurveKeyPoint(t *testing.T) {
	var bad G1
	bad[31] = 1
	bad[63] = 3 // (1, 3) is not on y^2 = x^3 + 3
	vk := VerifyingKey{Alpha: bad, Beta: g2Generator(t), IC: []G1{g1Generator(t)}}
	err := Verify(vk, Proof{A: g1Generator(t), B: g2Generator(t), C: g1Generator(t)}, nil)
	if err != ErrMalformedKey {
		t.Fatalf("want ErrMalformedKey, got %v", err)
	}
}
