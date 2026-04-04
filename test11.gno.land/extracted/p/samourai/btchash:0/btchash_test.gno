package btchash

import (
	"encoding/hex"
	"testing"
)

// hexToBytes decodes a hex string into bytes, panicking on error.
// Used only in tests.
func hexToBytes(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic("invalid hex in test: " + err.Error())
	}
	return b
}

// hexTo32 decodes a 64-char hex string into a [32]byte.
func hexTo32(s string) [32]byte {
	b := hexToBytes(s)
	if len(b) != 32 {
		panic("expected 32 bytes, got " + string(rune(len(b))))
	}
	var arr [32]byte
	copy(arr[:], b)
	return arr
}

// ================================================================
// SHA-256d Tests
// ================================================================

func TestSHA256d_Empty(t *testing.T) {
	// SHA-256d of empty input is a well-known constant:
	// SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
	// SHA-256d("") = SHA-256(above) = 5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456
	result := SHA256d([]byte{})
	expected := hexTo32("5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456")
	if result != expected {
		t.Errorf("SHA256d(empty): got %x, want %x", result, expected)
	}
}

func TestSHA256d_Hello(t *testing.T) {
	// SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
	// SHA-256d("hello") = SHA-256(above) = 9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50
	result := SHA256d([]byte("hello"))
	expected := hexTo32("9595c9df90075148eb06860365df33584b75bff782a510c6cd4883a419833d50")
	if result != expected {
		t.Errorf("SHA256d(hello): got %x, want %x", result, expected)
	}
}

func TestSHA256d_BitcoinGenesisBlockHeader(t *testing.T) {
	// Bitcoin Genesis Block (Block 0) header — 80 bytes
	// This is the canonical test vector for SHA-256d in the Bitcoin context.
	//
	// Header fields (all little-endian):
	//   Version:    01000000
	//   PrevHash:   0000000000000000000000000000000000000000000000000000000000000000
	//   MerkleRoot: 3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a
	//   Timestamp:  29ab5f49 (2009-01-03 18:15:05 UTC)
	//   Bits:       ffff001d
	//   Nonce:      1dac2b7c
	headerHex := "0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c"
	headerBytes := hexToBytes(headerHex)

	if len(headerBytes) != 80 {
		t.Fatalf("Genesis header should be 80 bytes, got %d", len(headerBytes))
	}

	result := SHA256d(headerBytes)

	// The hash in internal byte order:
	// 6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000
	//
	// In display order (reversed):
	// 000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f
	expectedInternal := hexTo32("6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000")
	if result != expectedInternal {
		t.Errorf("Genesis block hash (internal): got %x, want %x", result, expectedInternal)
	}

	// Verify display order via ReverseHash
	display := ReverseHash(result)
	expectedDisplay := hexTo32("000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
	if display != expectedDisplay {
		t.Errorf("Genesis block hash (display): got %x, want %x", display, expectedDisplay)
	}
}

func TestSHA256dBytes(t *testing.T) {
	result := SHA256dBytes([]byte("hello"))
	if len(result) != 32 {
		t.Errorf("SHA256dBytes should return 32 bytes, got %d", len(result))
	}
	// Compare with array version
	expected := SHA256d([]byte("hello"))
	for i := 0; i < 32; i++ {
		if result[i] != expected[i] {
			t.Errorf("SHA256dBytes mismatch at byte %d", i)
		}
	}
}

// ================================================================
// TaggedHash Tests (BIP 340/341)
// ================================================================

func TestTaggedHash_DomainSeparation(t *testing.T) {
	// Same data with different tags MUST produce different hashes
	data := []byte("test data")
	h1 := TaggedHash("TapTweak", data)
	h2 := TaggedHash("TapLeaf", data)
	h3 := TaggedHash("BIP0340/challenge", data)

	if h1 == h2 {
		t.Error("TaggedHash: TapTweak and TapLeaf produced same hash — domain separation broken")
	}
	if h1 == h3 {
		t.Error("TaggedHash: TapTweak and BIP0340/challenge produced same hash")
	}
	if h2 == h3 {
		t.Error("TaggedHash: TapLeaf and BIP0340/challenge produced same hash")
	}
}

func TestTaggedHash_Determinism(t *testing.T) {
	// Same tag + same data MUST always produce the same hash
	data := []byte("deterministic test")
	h1 := TaggedHash("TapTweak", data)
	h2 := TaggedHash("TapTweak", data)
	if h1 != h2 {
		t.Error("TaggedHash is not deterministic")
	}
}

func TestTaggedHash_EmptyData(t *testing.T) {
	// TaggedHash with empty data should still work
	// SHA-256("TapTweak") = known value
	// Result = SHA-256(tagHash || tagHash)
	result := TaggedHash("TapTweak", []byte{})
	if result == [32]byte{} {
		t.Error("TaggedHash(TapTweak, empty) should not be zero")
	}
}

func TestTaggedHashBytes(t *testing.T) {
	result := TaggedHashBytes("TapTweak", []byte("test"))
	if len(result) != 32 {
		t.Errorf("TaggedHashBytes should return 32 bytes, got %d", len(result))
	}
	// Compare with array version
	expected := TaggedHash("TapTweak", []byte("test"))
	for i := 0; i < 32; i++ {
		if result[i] != expected[i] {
			t.Errorf("TaggedHashBytes mismatch at byte %d", i)
		}
	}
}

// ================================================================
// MerkleNodeHash Tests
// ================================================================

func TestMerkleNodeHash(t *testing.T) {
	// MerkleNodeHash = SHA-256d(left || right)
	left := hexTo32("0000000000000000000000000000000000000000000000000000000000000001")
	right := hexTo32("0000000000000000000000000000000000000000000000000000000000000002")

	result := MerkleNodeHash(left, right)

	// Verify it equals SHA-256d of concatenation
	var combined [64]byte
	copy(combined[:32], left[:])
	copy(combined[32:], right[:])
	expected := SHA256d(combined[:])

	if result != expected {
		t.Errorf("MerkleNodeHash: got %x, want %x", result, expected)
	}
}

func TestMerkleNodeHash_OrderMatters(t *testing.T) {
	a := hexTo32("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	b := hexTo32("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

	h1 := MerkleNodeHash(a, b)
	h2 := MerkleNodeHash(b, a)

	if h1 == h2 {
		t.Error("MerkleNodeHash should be order-dependent")
	}
}

// ================================================================
// ReverseBytes / ReverseHash Tests
// ================================================================

func TestReverseBytes(t *testing.T) {
	input := []byte{0x01, 0x02, 0x03, 0x04}
	result := ReverseBytes(input)
	expected := []byte{0x04, 0x03, 0x02, 0x01}

	if len(result) != len(expected) {
		t.Fatalf("ReverseBytes length mismatch")
	}
	for i := range result {
		if result[i] != expected[i] {
			t.Errorf("ReverseBytes mismatch at %d: got %x, want %x", i, result[i], expected[i])
		}
	}

	// Verify original is not modified
	if input[0] != 0x01 {
		t.Error("ReverseBytes modified original slice")
	}
}

func TestReverseBytes_Empty(t *testing.T) {
	result := ReverseBytes([]byte{})
	if len(result) != 0 {
		t.Error("ReverseBytes of empty should be empty")
	}
}

func TestReverseHash(t *testing.T) {
	// Test with genesis block internal hash → display hash
	internal := hexTo32("6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000")
	display := ReverseHash(internal)
	expected := hexTo32("000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")

	if display != expected {
		t.Errorf("ReverseHash: got %x, want %x", display, expected)
	}

	// Double reverse should return original
	doubleReverse := ReverseHash(display)
	if doubleReverse != internal {
		t.Error("Double ReverseHash should return original")
	}
}
