package groth16

import (
	"bytes"
	"strings"
	"testing"
)

func TestPointAtInfinityAndDegenerateVK(t *testing.T) {
	vk := multiplierVK(t)
	proof := multiplierProof(t)
	inputs := multiplierInputs(t)

	// Point at infinity in Proof.A must not verify for a non-degenerate VK.
	pInfA := multiplierProof(t)
	pInfA.A = make([]byte, G1Size)
	if err := Verify(vk, pInfA, inputs); err != ErrVerificationFailed {
		t.Fatalf("expected ErrVerificationFailed for infinity Proof.A, got: %v", err)
	}

	// Point at infinity in Proof.B must not verify.
	pInfB := multiplierProof(t)
	pInfB.B = make([]byte, G2Size)
	if err := Verify(vk, pInfB, inputs); err != ErrVerificationFailed {
		t.Fatalf("expected ErrVerificationFailed for infinity Proof.B, got: %v", err)
	}

	// Degenerate zero Alpha in VK must be explicitly rejected.
	vkZeroAlpha := multiplierVK(t)
	vkZeroAlpha.Alpha = make([]byte, G1Size)
	if err := Verify(vkZeroAlpha, proof, inputs); err != ErrDegenerateVerifyingKey {
		t.Fatalf("expected ErrDegenerateVerifyingKey for zero Alpha, got: %v", err)
	}

	// Degenerate zero Beta in VK must be explicitly rejected.
	vkZeroBeta := multiplierVK(t)
	vkZeroBeta.Beta = make([]byte, G2Size)
	if err := Verify(vkZeroBeta, proof, inputs); err != ErrDegenerateVerifyingKey {
		t.Fatalf("expected ErrDegenerateVerifyingKey for zero Beta, got: %v", err)
	}

	// Degenerate zero Gamma in VK must be explicitly rejected.
	vkZeroGamma := multiplierVK(t)
	vkZeroGamma.Gamma = make([]byte, G2Size)
	if err := Verify(vkZeroGamma, proof, inputs); err != ErrDegenerateVerifyingKey {
		t.Fatalf("expected ErrDegenerateVerifyingKey for zero Gamma, got: %v", err)
	}

	// Degenerate zero Delta in VK must be explicitly rejected.
	vkZeroDelta := multiplierVK(t)
	vkZeroDelta.Delta = make([]byte, G2Size)
	if err := Verify(vkZeroDelta, proof, inputs); err != ErrDegenerateVerifyingKey {
		t.Fatalf("expected ErrDegenerateVerifyingKey for zero Delta, got: %v", err)
	}
}

func TestResourceLimitsAndOversizedArtifacts(t *testing.T) {
	// Exceeding MaxPublicInputs in ParsePublicInputsHex.
	tooManyHex := make([]string, MaxPublicInputs+1)
	for i := range tooManyHex {
		tooManyHex[i] = "0000000000000000000000000000000000000000000000000000000000000001"
	}
	if _, err := ParsePublicInputsHex(tooManyHex); err != ErrTooManyPublicInputs {
		t.Fatalf("expected ErrTooManyPublicInputs, got: %v", err)
	}

	// Exceeding MaxPublicInputs+1 in ParseVerifyingKeyHex.
	vk := multiplierVK(t)
	tooManyIC := make([]string, MaxPublicInputs+2)
	for i := range tooManyIC {
		tooManyIC[i] = "00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002"
	}
	if _, err := ParseVerifyingKeyHex(
		"00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002",
		strings.Repeat("01", G2Size),
		strings.Repeat("01", G2Size),
		strings.Repeat("01", G2Size),
		tooManyIC,
	); err != ErrTooManyPublicInputs {
		t.Fatalf("expected ErrTooManyPublicInputs for VK IC, got: %v", err)
	}

	// Exceeding MaxPublicInputs directly in Verify.
	bigVK := vk
	bigVK.IC = make([][]byte, MaxPublicInputs+2)
	for i := range bigVK.IC {
		bigVK.IC[i] = vk.IC[0]
	}
	bigInputs := make([][]byte, MaxPublicInputs+1)
	for i := range bigInputs {
		bigInputs[i] = make([]byte, ScalarSize)
	}
	if err := Verify(bigVK, multiplierProof(t), bigInputs); err != ErrTooManyPublicInputs {
		t.Fatalf("expected ErrTooManyPublicInputs in Verify, got: %v", err)
	}

	// Oversized packed proof bytes.
	if err := VerifyBytes(vk, make([]byte, ProofSize+1), multiplierInputs(t)); err != ErrInvalidEncoding {
		t.Fatalf("expected ErrInvalidEncoding for oversized packed proof, got: %v", err)
	}

	// Oversized hex string.
	if _, err := ParsePublicInputsHex([]string{strings.Repeat("00", 33)}); err != ErrInvalidEncoding {
		t.Fatalf("expected ErrInvalidEncoding for oversized scalar hex, got: %v", err)
	}
}

func TestCanonicalEncodingAndRoundTrip(t *testing.T) {
	p := multiplierProof(t)
	packed, err := EncodeProofBytes(p)
	if err != nil {
		t.Fatalf("EncodeProofBytes: %v", err)
	}
	if len(packed) != ProofSize {
		t.Fatalf("expected %d bytes, got %d", ProofSize, len(packed))
	}
	decoded, err := ParseProofBytes(packed)
	if err != nil {
		t.Fatalf("ParseProofBytes: %v", err)
	}
	if !bytes.Equal(decoded.A, p.A) || !bytes.Equal(decoded.B, p.B) || !bytes.Equal(decoded.C, p.C) {
		t.Fatalf("round-trip proof mismatch")
	}

	// 0x prefix and uppercase hex support.
	in, err := ParsePublicInputsHex([]string{
		"0x000000000000000000000000000000000000000000000000000000000000005B",
	})
	if err != nil || in[0][31] != 0x5b {
		t.Fatalf("0x/uppercase scalar parse failed: %v", err)
	}
}

// --- Isolated Verifier Gas Benchmarks (pre-parsed fixtures, no harness parsing in test body) ---

var (
	benchVK1     VerifyingKey
	benchProof1  Proof
	benchInputs1 [][]byte

	benchVK2     VerifyingKey
	benchProof2  Proof
	benchInputs2 [][]byte

	benchVK4     VerifyingKey
	benchInputs4 [][]byte

	benchVK8     VerifyingKey
	benchInputs8 [][]byte
)

func mustParseVK(alpha, beta, gamma, delta string, ic []string) VerifyingKey {
	vk, err := ParseVerifyingKeyHex(alpha, beta, gamma, delta, ic)
	if err != nil {
		panic(err.Error())
	}
	return vk
}

func mustParseProof(a, b, c string) Proof {
	p, err := ParseProofHex(a, b, c)
	if err != nil {
		panic(err.Error())
	}
	return p
}

func mustParseInputs(in []string) [][]byte {
	out, err := ParsePublicInputsHex(in)
	if err != nil {
		panic(err.Error())
	}
	return out
}

func init() {
	benchVK1 = mustParseVK(
		"27ef1e4b949df0d9925054b039c4750a76209e7051a2776b95d00ffda9730b3a0b0c08068893295be69f6fdb7aaaef7c0e2d7245c4670f27bca70686566d34e9",
		"2913998bed7684e656354d3fba940136c21ddf1d1a92ec4db20fb543a35ae1f82fab308dc6a04be0ffa4449f70afd5f6b6ac613c86fb805ce6c83487cd06f2c123f9c947a939ad96484aa8a5c4bc21f250d939fec8b4c87447812ad911ff06c229558caf12b4c8904bccd036c15e0876e1afc4097b3950f6a2f586159c9d8181",
		"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
		"19d4f2042c4e7b0078c8aa21a7b3717b5cf0afa8a923d5bd6b5f000dc114724f13ba01e9a5a4a32e3cd3e5d8b1c80eb8b099880f01ad2e5a529b75a20916ff48224c73080ee3981ee11206416b8218e2398c0ccf7dbad69f71531b75367443a22fface2ef2b0f80b73bb417cb0cbf0c9f75467817a1753e11834a43cfc9bb3b3",
		[]string{
			"11329a64c223361c9ccf7b944d19afe764221d515410d63e71a3137343e2033b1de9fd8d5675028623f017927ec4fe34929baf2e0dac016e2e669b1a8f17fc5a",
			"1dc6323602974e04a6abab316ff8549df0105f2abf97f8d062d9aa0844a23a6f031acf3e9ddb3a43d6366f6bb273132cdae91d945f828c9c2f152e6f8a2dc588",
		},
	)
	benchProof1 = mustParseProof(
		"08f6d917ac1ac88476899b1e7e7d0999ead29c1d8ac15a153d77d30c941368a530585e3bb78069ca3cab46b308d4cef9d8b6bfe96d1d08b7ee056911a0855243",
		"100fcb919d51af5609be4b42bf81f43694615722ae53151651f01d343772a23503b622ebd931605a3792cdbbeda39891eb77275a506a172181afe6d3a0ab3f4e164880afd3de6c95c2779314923c4f07895b52833094e248f85a025d7e270ad2272c0bd524a12eb79b88266ca43cc1fa33449dbb423d1c11121ef52a750c6f6a",
		"12e48f4cecca6a6dab7c15269c9dc5704adabf7f7959177d2d50647e3fefb2bc1d670683ef34d88cd815d032a69a79d6cecc6d53c55d15201de3b0b970201844",
	)
	benchInputs1 = mustParseInputs([]string{"000000000000000000000000000000000000000000000000000000000000005b"})

	benchVK2 = mustParseVK(
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
	benchProof2 = mustParseProof(
		"0b8d90e7660675bc45800643d51a670a4d8e8a2483d0b9f8d7bab3e813506f162f6551a3a70009ebe1d0dfbf377b0e9955d095fb97f34e215e1fb5fd02f538b9",
		"2385fe8cdf22d3802c3b50c2b382541aa8efc124381537eeb62b83d31dbc2a240fcbbb3c1a2e08a74cec9bd5968887ededf31e08e0dae48d5acc298dc4cf34642d1a21ed69e10caf1519abf44917a6f08da7d479365f4256aa65f4be2e1960000887cd2492497d38e475286c2659aefc3b3faa1668f0a783c160993b3838edc3",
		"0677ff0906b9953eb5d1de720e8777c751d265b5a5bf45e4f156c4906da8236c2cffa4c5a2bff7ec722f1916a8e069150257e2175748f0383ccde26986854b78",
	)
	benchInputs2 = mustParseInputs([]string{
		"0000000000000000000000000000000000000000000000000000000000000001",
		"0000000000000000000000000000000000000000000000000000000000000019",
	})

	g1Gen := make([]byte, G1Size)
	g1Gen[31] = 1
	g1Gen[63] = 2

	benchVK4 = mustParseVK(
		"27ef1e4b949df0d9925054b039c4750a76209e7051a2776b95d00ffda9730b3a0b0c08068893295be69f6fdb7aaaef7c0e2d7245c4670f27bca70686566d34e9",
		"2913998bed7684e656354d3fba940136c21ddf1d1a92ec4db20fb543a35ae1f82fab308dc6a04be0ffa4449f70afd5f6b6ac613c86fb805ce6c83487cd06f2c123f9c947a939ad96484aa8a5c4bc21f250d939fec8b4c87447812ad911ff06c229558caf12b4c8904bccd036c15e0876e1afc4097b3950f6a2f586159c9d8181",
		"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
		"19d4f2042c4e7b0078c8aa21a7b3717b5cf0afa8a923d5bd6b5f000dc114724f13ba01e9a5a4a32e3cd3e5d8b1c80eb8b099880f01ad2e5a529b75a20916ff48224c73080ee3981ee11206416b8218e2398c0ccf7dbad69f71531b75367443a22fface2ef2b0f80b73bb417cb0cbf0c9f75467817a1753e11834a43cfc9bb3b3",
		[]string{
			"11329a64c223361c9ccf7b944d19afe764221d515410d63e71a3137343e2033b1de9fd8d5675028623f017927ec4fe34929baf2e0dac016e2e669b1a8f17fc5a",
			"1dc6323602974e04a6abab316ff8549df0105f2abf97f8d062d9aa0844a23a6f031acf3e9ddb3a43d6366f6bb273132cdae91d945f828c9c2f152e6f8a2dc588",
		},
	)
	benchVK4.IC = append(benchVK4.IC, g1Gen, g1Gen, g1Gen)
	benchInputs4 = append(mustParseInputs([]string{"000000000000000000000000000000000000000000000000000000000000005b"}), make([]byte, 32), make([]byte, 32), make([]byte, 32))

	benchVK8 = mustParseVK(
		"27ef1e4b949df0d9925054b039c4750a76209e7051a2776b95d00ffda9730b3a0b0c08068893295be69f6fdb7aaaef7c0e2d7245c4670f27bca70686566d34e9",
		"2913998bed7684e656354d3fba940136c21ddf1d1a92ec4db20fb543a35ae1f82fab308dc6a04be0ffa4449f70afd5f6b6ac613c86fb805ce6c83487cd06f2c123f9c947a939ad96484aa8a5c4bc21f250d939fec8b4c87447812ad911ff06c229558caf12b4c8904bccd036c15e0876e1afc4097b3950f6a2f586159c9d8181",
		"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
		"19d4f2042c4e7b0078c8aa21a7b3717b5cf0afa8a923d5bd6b5f000dc114724f13ba01e9a5a4a32e3cd3e5d8b1c80eb8b099880f01ad2e5a529b75a20916ff48224c73080ee3981ee11206416b8218e2398c0ccf7dbad69f71531b75367443a22fface2ef2b0f80b73bb417cb0cbf0c9f75467817a1753e11834a43cfc9bb3b3",
		[]string{
			"11329a64c223361c9ccf7b944d19afe764221d515410d63e71a3137343e2033b1de9fd8d5675028623f017927ec4fe34929baf2e0dac016e2e669b1a8f17fc5a",
			"1dc6323602974e04a6abab316ff8549df0105f2abf97f8d062d9aa0844a23a6f031acf3e9ddb3a43d6366f6bb273132cdae91d945f828c9c2f152e6f8a2dc588",
		},
	)
	for i := 0; i < 7; i++ {
		benchVK8.IC = append(benchVK8.IC, g1Gen)
	}
	benchInputs8 = mustParseInputs([]string{"000000000000000000000000000000000000000000000000000000000000005b"})
	for i := 0; i < 7; i++ {
		benchInputs8 = append(benchInputs8, make([]byte, 32))
	}
}

func TestGasBench_0_NoOp(t *testing.T) {
}

func TestGasBench_1_Verify1Input(t *testing.T) {
	if err := Verify(benchVK1, benchProof1, benchInputs1); err != nil {
		t.Fatalf("verify 1 input: %v", err)
	}
}

func TestGasBench_2_Verify2Inputs(t *testing.T) {
	if err := Verify(benchVK2, benchProof2, benchInputs2); err != nil {
		t.Fatalf("verify 2 inputs: %v", err)
	}
}

func TestGasBench_3_Verify4Inputs(t *testing.T) {
	if err := Verify(benchVK4, benchProof1, benchInputs4); err != nil {
		t.Fatalf("verify 4 inputs: %v", err)
	}
}

func TestGasBench_4_Verify8Inputs(t *testing.T) {
	if err := Verify(benchVK8, benchProof1, benchInputs8); err != nil {
		t.Fatalf("verify 8 inputs: %v", err)
	}
}
