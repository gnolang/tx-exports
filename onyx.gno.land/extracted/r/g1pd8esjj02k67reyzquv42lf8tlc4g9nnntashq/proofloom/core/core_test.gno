package core

import "testing"

func TestIsValidAddress(cur realm, t *testing.T) {
	valid := []string{
		"g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq",
		"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",
	}
	for _, a := range valid {
		if !IsValidAddress(a) {
			t.Fatalf("expected valid: %s", a)
		}
	}
	invalid := []string{
		"", "x1abc", "g2pd8esjj02k67reyzquv42lf8tlc4g9nnntashq",
		"G1PD8ESJJ02K67REYZQUV42LF8TLC4G9NNNTASHQ",
		"g1pd8esjj02k67reyzquv42lf8tlc4g9nnntash;key",
		"g1",
	}
	for _, a := range invalid {
		if IsValidAddress(a) {
			t.Fatalf("expected invalid: %q", a)
		}
	}
}

func TestIsValidDigest(cur realm, t *testing.T) {
	good := "a3f5c2d1b0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3"
	if !IsValidDigest(good) {
		t.Fatal("expected digest valid")
	}
	if IsValidDigest("a3f5c2d1") {
		t.Fatal("too short must be invalid")
	}
	if IsValidDigest("A3F5C2D1B0E9F8A7B6C5D4E3F2A1B0C9D8E7F6A5B4C3D2E1F0A9B8C7D6E5F4A3") {
		t.Fatal("uppercase must be invalid")
	}
	if IsValidDigest(good[:63] + "g") {
		t.Fatal("non-hex must be invalid")
	}
}

func TestIsValidID(cur realm, t *testing.T) {
	if !IsValidID("my-project") || !IsValidID("core-api") || !IsValidID("a1") {
		t.Fatal("expected valid ids")
	}
	for _, bad := range []string{"", "-x", "x-", "Big", "a b", string(make([]byte, 65))} {
		if IsValidID(bad) {
			t.Fatalf("expected invalid: %q", bad)
		}
	}
}

func TestIsValidVersionAndHash(cur realm, t *testing.T) {
	if !IsValidVersion("1.2.3") || !IsValidVersion("2.0.0-rc.1") {
		t.Fatal("expected versions valid")
	}
	if IsValidVersion("") || IsValidVersion("1 2") {
		t.Fatal("expected versions invalid")
	}
	if !IsValidShortHash("0123abcd") || IsValidShortHash("abc") {
		t.Fatal("short hash validation broken")
	}
}

func TestComposeIDs(cur realm, t *testing.T) {
	if got := ComposeReleaseID("core-api", "1.2.3"); got != "core-api-1.2.3" {
		t.Fatalf("unexpected release id %q", got)
	}
	got := ComposeAttestationID("core-api-1.2.3", "BUILD_PROVENANCE", "g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq")
	want := "core-api-1.2.3-build_provenance-g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq"
	if got != want {
		t.Fatalf("unexpected attestation id %q", got)
	}
}

func TestBoundedText(cur realm, t *testing.T) {
	if !BoundedText("ok", 10) {
		t.Fatal("bounded failed")
	}
	if BoundedText(string(make([]byte, 513)), MaxTextLen) {
		t.Fatal("over-bounded passed")
	}
}
