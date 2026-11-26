package groth16

import (
	"testing"
)

func multiplierVK(t *testing.T) VerifyingKey {
	t.Helper()
	vk, err := ParseVerifyingKeyHex(
		"27ef1e4b949df0d9925054b039c4750a76209e7051a2776b95d00ffda9730b3a0b0c08068893295be69f6fdb7aaaef7c0e2d7245c4670f27bca70686566d34e9",
		"2913998bed7684e656354d3fba940136c21ddf1d1a92ec4db20fb543a35ae1f82fab308dc6a04be0ffa4449f70afd5f6b6ac613c86fb805ce6c83487cd06f2c123f9c947a939ad96484aa8a5c4bc21f250d939fec8b4c87447812ad911ff06c229558caf12b4c8904bccd036c15e0876e1afc4097b3950f6a2f586159c9d8181",
		"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
		"19d4f2042c4e7b0078c8aa21a7b3717b5cf0afa8a923d5bd6b5f000dc114724f13ba01e9a5a4a32e3cd3e5d8b1c80eb8b099880f01ad2e5a529b75a20916ff48224c73080ee3981ee11206416b8218e2398c0ccf7dbad69f71531b75367443a22fface2ef2b0f80b73bb417cb0cbf0c9f75467817a1753e11834a43cfc9bb3b3",
		[]string{
			"11329a64c223361c9ccf7b944d19afe764221d515410d63e71a3137343e2033b1de9fd8d5675028623f017927ec4fe34929baf2e0dac016e2e669b1a8f17fc5a",
			"1dc6323602974e04a6abab316ff8549df0105f2abf97f8d062d9aa0844a23a6f031acf3e9ddb3a43d6366f6bb273132cdae91d945f828c9c2f152e6f8a2dc588",
		},
	)
	if err != nil {
		t.Fatalf("parse multiplier vk: %v", err)
	}
	return vk
}

func multiplierProof(t *testing.T) Proof {
	t.Helper()
	p, err := ParseProofHex(
		"08f6d917ac1ac88476899b1e7e7d0999ead29c1d8ac15a153d77d30c941368a530585e3bb78069ca3cab46b308d4cef9d8b6bfe96d1d08b7ee056911a0855243",
		"100fcb919d51af5609be4b42bf81f43694615722ae53151651f01d343772a23503b622ebd931605a3792cdbbeda39891eb77275a506a172181afe6d3a0ab3f4e164880afd3de6c95c2779314923c4f07895b52833094e248f85a025d7e270ad2272c0bd524a12eb79b88266ca43cc1fa33449dbb423d1c11121ef52a750c6f6a",
		"12e48f4cecca6a6dab7c15269c9dc5704adabf7f7959177d2d50647e3fefb2bc1d670683ef34d88cd815d032a69a79d6cecc6d53c55d15201de3b0b970201844",
	)
	if err != nil {
		t.Fatalf("parse multiplier proof: %v", err)
	}
	return p
}

func multiplierInputs(t *testing.T) [][]byte {
	t.Helper()
	in, err := ParsePublicInputsHex([]string{
		"000000000000000000000000000000000000000000000000000000000000005b", // 91
	})
	if err != nil {
		t.Fatalf("parse multiplier inputs: %v", err)
	}
	return in
}

func sumOfSquaresVK(t *testing.T) VerifyingKey {
	t.Helper()
	vk, err := ParseVerifyingKeyHex(
		"27ef1e4b949df0d9925054b039c4750a76209e7051a2776b95d00ffda9730b3a0b0c08068893295be69f6fdb7aaaef7c0e2d7245c4670f27bca70686566d34e9",
		"2913998bed7684e656354d3fba940136c21ddf1d1a92ec4db20fb543a35ae1f82fab308dc6a04be0ffa4449f70afd5f6b6ac613c86fb805ce6c83487cd06f2c123f9c947a939ad96484aa8a5c4bc21f250d939fec8b4c87447812ad911ff06c229558caf12b4c8904bccd036c15e0876e1afc4097b3950f6a2f586159c9d8181",
		"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
		"2a3e96b2cea23dfa8a470d745c142f3ba633d48e330df2f00f436723a2b49852083969e1a6810ca500900c4e75d9c22c6fccc6f2be2d99cd9a9636a1b3b5ac742452a4ae9fb17ffef1b5ceef40e2efe23d30f1344a4518842ca9da0ce861e08018f7fe9dd36308c9b060b49b7fa6bf714d34dd4349ec079b802fe2d1a4ac1044",
		[]string{
			"074f576637c9bc2f00417ab77dc282d964094f74d321378c9e234c46e96e1b9006db8b1dcebfb44b4528ff7db52af7a271956a77577fecb7c75e7158637086a4",
			"20b2ee50588368cfd5a5bb344a48ec10c3278f941390a153d15c008b9a9ce10206d391a6702c0127fbd06d0fd81f129387ea5b04429735f581949b0ae1bee975",
			"0b96aec37452f296cff008446b336036354d42601a4e4a1ec60a9e10a9e76daf07ff2dc00a3de9370f7223657a604873bf57b75983b5d3d32bc95dead99e5110",
		},
	)
	if err != nil {
		t.Fatalf("parse sum_of_squares vk: %v", err)
	}
	return vk
}

func sumOfSquaresProof(t *testing.T) Proof {
	t.Helper()
	p, err := ParseProofHex(
		"0b8d90e7660675bc45800643d51a670a4d8e8a2483d0b9f8d7bab3e813506f162f6551a3a70009ebe1d0dfbf377b0e9955d095fb97f34e215e1fb5fd02f538b9",
		"2385fe8cdf22d3802c3b50c2b382541aa8efc124381537eeb62b83d31dbc2a240fcbbb3c1a2e08a74cec9bd5968887ededf31e08e0dae48d5acc298dc4cf34642d1a21ed69e10caf1519abf44917a6f08da7d479365f4256aa65f4be2e1960000887cd2492497d38e475286c2659aefc3b3faa1668f0a783c160993b3838edc3",
		"0677ff0906b9953eb5d1de720e8777c751d265b5a5bf45e4f156c4906da8236c2cffa4c5a2bff7ec722f1916a8e069150257e2175748f0383ccde26986854b78",
	)
	if err != nil {
		t.Fatalf("parse sum_of_squares proof: %v", err)
	}
	return p
}

func sumOfSquaresInputs(t *testing.T) [][]byte {
	t.Helper()
	in, err := ParsePublicInputsHex([]string{
		"0000000000000000000000000000000000000000000000000000000000000001", // ok = 1
		"0000000000000000000000000000000000000000000000000000000000000019", // target = 25
	})
	if err != nil {
		t.Fatalf("parse sum_of_squares inputs: %v", err)
	}
	return in
}

// 1. Valid proof accepted (both independent circuits: 1-input and 2-input).
func TestValidProofsAccepted(t *testing.T) {
	if err := Verify(multiplierVK(t), multiplierProof(t), multiplierInputs(t)); err != nil {
		t.Fatalf("multiplier valid proof rejected: %v", err)
	}
	if err := Verify(sumOfSquaresVK(t), sumOfSquaresProof(t), sumOfSquaresInputs(t)); err != nil {
		t.Fatalf("sum_of_squares valid proof rejected: %v", err)
	}

	// Also verify packed 256-byte proof path.
	p := multiplierProof(t)
	packed := make([]byte, 0, ProofSize)
	packed = append(packed, p.A...)
	packed = append(packed, p.B...)
	packed = append(packed, p.C...)
	if err := VerifyBytes(multiplierVK(t), packed, multiplierInputs(t)); err != nil {
		t.Fatalf("VerifyBytes valid proof rejected: %v", err)
	}
}

// 2. Modified proof rejected.
func TestModifiedProofRejected(t *testing.T) {
	vk := multiplierVK(t)
	inputs := multiplierInputs(t)

	// Flip a bit in A (still likely off-curve -> ErrInvalidCurvePoint, or wrong point -> ErrVerificationFailed).
	pA := multiplierProof(t)
	pA.A[31] ^= 0x01
	if err := Verify(vk, pA, inputs); err == nil {
		t.Fatalf("expected modified proof.A to be rejected")
	}

	// Swap A with another valid on-curve G1 point (sum_of_squares proof.A).
	pSwap := multiplierProof(t)
	pSwap.A = sumOfSquaresProof(t).A
	if err := Verify(vk, pSwap, inputs); err != ErrVerificationFailed {
		t.Fatalf("expected ErrVerificationFailed for swapped valid G1 A, got: %v", err)
	}

	// Swap B with another valid G2 point.
	pSwapB := multiplierProof(t)
	pSwapB.B = sumOfSquaresProof(t).B
	if err := Verify(vk, pSwapB, inputs); err != ErrVerificationFailed {
		t.Fatalf("expected ErrVerificationFailed for swapped valid G2 B, got: %v", err)
	}

	// Swap C with another valid G1 point.
	pSwapC := multiplierProof(t)
	pSwapC.C = sumOfSquaresProof(t).C
	if err := Verify(vk, pSwapC, inputs); err != ErrVerificationFailed {
		t.Fatalf("expected ErrVerificationFailed for swapped valid G1 C, got: %v", err)
	}
}

// 3. Modified public input rejected.
func TestModifiedPublicInputRejected(t *testing.T) {
	vk := multiplierVK(t)
	proof := multiplierProof(t)
	inputs := multiplierInputs(t)
	inputs[0][31] = 0x5c // 92 instead of 91

	if err := Verify(vk, proof, inputs); err != ErrVerificationFailed {
		t.Fatalf("expected ErrVerificationFailed for modified public input, got: %v", err)
	}
}

// 4. Incorrect verification key rejected.
func TestIncorrectVerifyingKeyRejected(t *testing.T) {
	// Use sumOfSquares VK with multiplier proof + 2 dummy inputs, and also mutate multiplier VK.
	vk := multiplierVK(t)
	vk.Alpha = sumOfSquaresProof(t).A // valid G1 point, wrong Alpha
	if err := Verify(vk, multiplierProof(t), multiplierInputs(t)); err != ErrVerificationFailed {
		t.Fatalf("expected ErrVerificationFailed for incorrect VK.Alpha, got: %v", err)
	}

	vk2 := sumOfSquaresVK(t)
	if err := Verify(vk2, multiplierProof(t), sumOfSquaresInputs(t)); err != ErrVerificationFailed {
		t.Fatalf("expected ErrVerificationFailed for mismatched circuit VK, got: %v", err)
	}
}

// 5. Incorrect number of public inputs rejected.
func TestIncorrectPublicInputCountRejected(t *testing.T) {
	vk := multiplierVK(t)
	proof := multiplierProof(t)

	if err := Verify(vk, proof, nil); err != ErrInvalidInputCount {
		t.Fatalf("expected ErrInvalidInputCount for 0 inputs, got: %v", err)
	}
	twoInputs := append(multiplierInputs(t), multiplierInputs(t)[0])
	if err := Verify(vk, proof, twoInputs); err != ErrInvalidInputCount {
		t.Fatalf("expected ErrInvalidInputCount for 2 inputs, got: %v", err)
	}
}

// 6. Malformed curve points rejected (off-curve G1 and G2).
func TestMalformedCurvePointsRejected(t *testing.T) {
	vk := multiplierVK(t)
	inputs := multiplierInputs(t)

	// (1, 3) is not on BN254 G1 (y^2 = x^3 + 3 => 9 != 4).
	p := multiplierProof(t)
	badG1 := make([]byte, 64)
	badG1[31] = 1
	badG1[63] = 3
	p.A = badG1
	if err := Verify(vk, p, inputs); err != ErrInvalidCurvePoint {
		t.Fatalf("expected ErrInvalidCurvePoint for off-curve G1, got: %v", err)
	}

	// Off-curve G2 point (all 1s in low bytes).
	p2 := multiplierProof(t)
	badG2 := make([]byte, 128)
	badG2[31] = 1
	badG2[63] = 1
	badG2[95] = 1
	badG2[127] = 1
	p2.B = badG2
	if err := Verify(vk, p2, inputs); err != ErrInvalidCurvePoint {
		t.Fatalf("expected ErrInvalidCurvePoint for off-curve G2, got: %v", err)
	}
}

// 7. Noncanonical field elements rejected (Fp >= p and Fr >= r).
func TestNonCanonicalFieldElementsRejected(t *testing.T) {
	vk := multiplierVK(t)
	proof := multiplierProof(t)

	// Scalar == r (must be rejected; crypto/bn254 G1Mul would reduce mod r if unchecked).
	nonCanonScalar := make([]byte, 32)
	copy(nonCanonScalar, bn254ScalarFieldR[:])
	if err := Verify(vk, proof, [][]byte{nonCanonScalar}); err != ErrNonCanonicalScalar {
		t.Fatalf("expected ErrNonCanonicalScalar for scalar == r, got: %v", err)
	}

	// Scalar > r (all 0xff).
	maxScalar := make([]byte, 32)
	for i := range maxScalar {
		maxScalar[i] = 0xff
	}
	if err := Verify(vk, proof, [][]byte{maxScalar}); err != ErrNonCanonicalScalar {
		t.Fatalf("expected ErrNonCanonicalScalar for scalar == 2^256-1, got: %v", err)
	}

	// G1 coordinate == p.
	pBadG1 := multiplierProof(t)
	copy(pBadG1.A[0:32], bn254BaseFieldP[:])
	if err := Verify(vk, pBadG1, multiplierInputs(t)); err != ErrNonCanonicalField {
		t.Fatalf("expected ErrNonCanonicalField for G1.x == p, got: %v", err)
	}

	// G2 coordinate == p.
	pBadG2 := multiplierProof(t)
	copy(pBadG2.B[64:96], bn254BaseFieldP[:])
	if err := Verify(vk, pBadG2, multiplierInputs(t)); err != ErrNonCanonicalField {
		t.Fatalf("expected ErrNonCanonicalField for G2.y_imag == p, got: %v", err)
	}
}

// 8. Invalid subgroup points rejected (on-curve G2 point outside r-torsion subgroup).
func TestInvalidSubgroupG2Rejected(t *testing.T) {
	vk := multiplierVK(t)
	inputs := multiplierInputs(t)

	invalidSubgroupB, err := decodeExactHex(
		"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000204ed8cf98795e6ff221299312d1758032001ee7d71ca132fe307d56157ed9d692044dbfa9f9e977067b6591653b277985f621d6a969ba7794bc97597d23bfb79",
		G2Size,
	)
	if err != nil {
		t.Fatalf("decode invalid subgroup point: %v", err)
	}

	p := multiplierProof(t)
	p.B = invalidSubgroupB
	if err := Verify(vk, p, inputs); err != ErrInvalidCurvePoint {
		t.Fatalf("expected ErrInvalidCurvePoint for invalid-subgroup G2 point, got: %v", err)
	}
}

// 9. Invalid encodings handled safely without unexpected panics.
func TestInvalidEncodingsNoPanic(t *testing.T) {
	vk := multiplierVK(t)
	proof := multiplierProof(t)
	inputs := multiplierInputs(t)

	if err := Verify(VerifyingKey{}, proof, inputs); err == nil {
		t.Fatalf("expected error for empty VK")
	}
	if err := Verify(vk, Proof{}, inputs); err == nil {
		t.Fatalf("expected error for empty Proof")
	}
	if err := Verify(vk, proof, [][]byte{{0x01}}); err != ErrInvalidEncoding {
		t.Fatalf("expected ErrInvalidEncoding for short scalar, got: %v", err)
	}
	if err := VerifyBytes(vk, []byte{1, 2, 3}, inputs); err != ErrInvalidEncoding {
		t.Fatalf("expected ErrInvalidEncoding for short packed proof, got: %v", err)
	}
	if _, err := ParseProofHex("zzzz", "00", "00"); err != ErrInvalidEncoding {
		t.Fatalf("expected ErrInvalidEncoding for invalid hex, got: %v", err)
	}
	if _, err := ParsePublicInputsHex([]string{"1234"}); err != ErrInvalidEncoding {
		t.Fatalf("expected ErrInvalidEncoding for short hex scalar, got: %v", err)
	}
	if _, err := ParseVerifyingKeyHex("00", "00", "00", "00", nil); err != ErrInvalidVerifyingKey {
		t.Fatalf("expected ErrInvalidVerifyingKey for nil IC, got: %v", err)
	}
}
