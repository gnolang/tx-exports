package commitreveal

import (
	"strings"
	"testing"
)

func TestComputeHashGoldenVectors(t *testing.T) {
	// These inputs and expected hashes come from fixtures/golden-vectors.json.
	vectors := []struct {
		id, domain, roundKey, caller, payload, salt, expectedSha256 string
	}{
		{
			"V1",
			"colorado/v1",
			"D:20782:wca",
			"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",
			"R U R' U' F2 L D' B",
			"a1b2c3d4e5f60718293a4b5c6d7e8f90",
			"0531053c3b58a3c1433ff5c7710e5452eb8faef84d292816ae758291ee9a0fe6",
		},
		{
			"V2",
			"colorado/v1",
			"D:20782:twisted",
			"g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj",
			"Rw U' F x2 L' D",
			"00112233445566778899aabbccddeeff",
			"8fce2e46cedb3ba0fc0aea2c007c3d5701580ae4ccb1d6b4f99b90dd25e2cc57",
		},
		{
			"V3",
			"colorado/v1",
			"Q:1",
			"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",
			"U R F' L' D B",
			"deadbeefcafebabe0123456789abcdef",
			"668f57d5e353bfb85534666f9d2d0e48bd841ed68780f0d5fa295df88a689a44",
		},
	}
	for _, vector := range vectors {
		got := ComputeHash(vector.domain, vector.roundKey, vector.caller, vector.payload, vector.salt)
		if got != vector.expectedSha256 {
			t.Errorf("%s: got %q, want %q", vector.id, got, vector.expectedSha256)
		}
	}
}

func TestComputeHashMultibyteUTF8ByteLength(t *testing.T) {
	// SHA-256 of 6:domain|5:round|6:caller|4:🧊|16:0123456789abcdef.
	const want = "a40fe5f5a5b2353d5993368749705d92eca03adf48e52cd526f045f5896be4ed"
	if got := ComputeHash("domain", "round", "caller", "🧊", "0123456789abcdef"); got != want {
		t.Errorf("four-byte payload: got %q, want %q", got, want)
	}
}

func TestVerifyRevealMatchMismatchAndSaltBounds(t *testing.T) {
	const domain, roundKey, caller, payload, salt = "domain", "round", "caller", "R U", "0123456789abcdef"
	rec := Record{CommitHash: ComputeHash(domain, roundKey, caller, payload, salt)}
	if err := VerifyReveal(rec, domain, roundKey, caller, payload, salt); err != nil {
		t.Errorf("matching reveal: %v", err)
	}

	mismatches := []struct {
		name, caller, payload, salt string
	}{
		{"wrong payload", caller, "U R", salt},
		{"wrong salt", caller, payload, "1123456789abcdef"},
		{"wrong caller", "another caller", payload, salt},
	}
	for _, tc := range mismatches {
		err := VerifyReveal(rec, domain, roundKey, tc.caller, tc.payload, tc.salt)
		if err == nil || err.Error() != "ERR_HASH_MISMATCH" {
			t.Errorf("%s: got %v, want ERR_HASH_MISMATCH", tc.name, err)
		}
	}

	salts := []struct {
		name, salt string
		valid      bool
	}{
		{"15 bytes", strings.Repeat("!", 15), false},
		{"16 bytes at ASCII bounds", "!123456789abcde~", true},
		{"128 bytes", strings.Repeat("~", 128), true},
		{"129 bytes", strings.Repeat("~", 129), false},
		{"space", "01234567 9abcdef", false},
		{"tab", "01234567\t9abcdef", false},
		{"DEL", "01234567\x7f9abcdef", false},
		{"non-ASCII", "01234567é9abcdef", false},
	}
	for _, tc := range salts {
		if got := IsValidSalt(tc.salt); got != tc.valid {
			t.Errorf("%s: IsValidSalt = %v, want %v", tc.name, got, tc.valid)
		}
		rec := Record{CommitHash: ComputeHash(domain, roundKey, caller, payload, tc.salt)}
		err := VerifyReveal(rec, domain, roundKey, caller, payload, tc.salt)
		if tc.valid {
			if err != nil {
				t.Errorf("%s: matching reveal returned %v", tc.name, err)
			}
		} else if err == nil || err.Error() != "ERR_HASH_MISMATCH" {
			t.Errorf("%s: got %v, want ERR_HASH_MISMATCH despite a matching hash", tc.name, err)
		}
	}
}

func TestIsValidHashHexAndCanPrune(t *testing.T) {
	const valid = "0531053c3b58a3c1433ff5c7710e5452eb8faef84d292816ae758291ee9a0fe6"
	if !IsValidHashHex(valid) {
		t.Error("valid lowercase hash was rejected")
	}
	for _, hash := range []string{strings.ToUpper(valid), valid[:63], valid + "0", "g" + valid[1:]} {
		if IsValidHashHex(hash) {
			t.Errorf("invalid hash %q was accepted", hash)
		}
		err := VerifyReveal(Record{CommitHash: hash}, "domain", "round", "caller", "R U", "0123456789abcdef")
		if err == nil || err.Error() != "ERR_HASH_MISMATCH" {
			t.Errorf("malformed hash %q: got %v, want ERR_HASH_MISMATCH", hash, err)
		}
	}
	if CanPrune(1000, 999) || !CanPrune(1000, 1000) || !CanPrune(1000, 1001) {
		t.Error("pruning should open at the reveal deadline and stay open")
	}
}
