package veil_registry

import (
	"strings"
	"testing"
)

func TestRegistryLifecycleAndAuthorization(cur realm, t *testing.T) {
	pub := address("g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04")
	attacker := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")

	testing.SetRealm(testing.NewUserRealm(pub))
	id := RegisterVerifier(
		cross(cur),
		"gno.land/r/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/semaphore_depth10_verifier",
		"a6789bea2b941dbdb86e887cc9f958aa447dcbfa9ff725a886d99db2c2c47c3b",
		"groth16",
		"bn254",
		4,
		"Semaphore v4.13.0 depth-10 (PSE ceremony)",
		"v1.0.0",
	)
	if id != 1 {
		t.Fatalf("expected id 1, got %d", id)
	}
	if !strings.Contains(GetVerifier(1), "|active") {
		t.Fatalf("expected active record, got %s", GetVerifier(1))
	}

	// Duplicate path rejected.
	if r := revive(func() {
		RegisterVerifier(cross(cur), "gno.land/r/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/semaphore_depth10_verifier", "abc", "groth16", "bn254", 4, "dup", "v1")
	}); r == nil {
		t.Fatalf("expected duplicate path panic")
	}

	// Unauthorized deprecation rejected.
	testing.SetRealm(testing.NewUserRealm(attacker))
	if r := revive(func() { DeprecateVerifier(cross(cur), 1) }); r == nil {
		t.Fatalf("expected unauthorized deprecation panic")
	}

	// Publisher deprecation succeeds; double-deprecation rejected.
	testing.SetRealm(testing.NewUserRealm(pub))
	DeprecateVerifier(cross(cur), 1)
	if !strings.Contains(GetVerifier(1), "|deprecated") {
		t.Fatalf("expected deprecated record, got %s", GetVerifier(1))
	}
	if r := revive(func() { DeprecateVerifier(cross(cur), 1) }); r == nil {
		t.Fatalf("expected double-deprecation panic")
	}

	// Max permitted bounds accepted; max+1 and invalid inputs rejected.
	nsPrefix := "gno.land/r/" + pub.String() + "/"
	maxPath := nsPrefix + strings.Repeat("a", MaxPkgPathLen-len(nsPrefix))
	maxFP := strings.Repeat("b", MaxFingerprintLen)
	maxMeta := strings.Repeat("c", MaxMetadataLen)
	maxVer := strings.Repeat("d", MaxVersionLen)
	id2 := RegisterVerifier(cross(cur), maxPath, maxFP, "groth16", "bn254", MaxPublicInputs, maxMeta, maxVer)
	if id2 != 2 || GetRecordCount() != 2 {
		t.Fatalf("expected id2=2, got %d", id2)
	}

	// Namespace hijacking and delimiter injection rejected.
	testing.SetRealm(testing.NewUserRealm(attacker))
	if r := revive(func() {
		RegisterVerifier(cross(cur), nsPrefix+"hijack", "fp", "groth16", "bn254", 1, "", "v1")
	}); r == nil {
		t.Fatalf("expected namespace ownership panic")
	}
	testing.SetRealm(testing.NewUserRealm(pub))
	if r := revive(func() {
		RegisterVerifier(cross(cur), nsPrefix+"del", "fp|bad", "groth16", "bn254", 1, "", "v1")
	}); r == nil {
		t.Fatalf("expected delimiter injection panic")
	}
	if r := revive(func() {
		RegisterVerifier(cross(cur), nsPrefix+"ctrl", "fp", "groth16", "bn254", 1, "bad\nmeta", "v1")
	}); r == nil {
		t.Fatalf("expected control char panic")
	}

	// Max + 1 bounds rejected.
	if r := revive(func() {
		RegisterVerifier(cross(cur), maxPath+"x", "fp", "groth16", "bn254", 1, "", "v1")
	}); r == nil {
		t.Fatalf("expected oversized pkgPath panic")
	}
	if r := revive(func() {
		RegisterVerifier(cross(cur), nsPrefix+"fp_over", maxFP+"x", "groth16", "bn254", 1, "", "v1")
	}); r == nil {
		t.Fatalf("expected oversized fingerprint panic")
	}
	if r := revive(func() {
		RegisterVerifier(cross(cur), nsPrefix+"meta_over", "fp", "groth16", "bn254", 1, maxMeta+"x", "v1")
	}); r == nil {
		t.Fatalf("expected oversized metadata panic")
	}
	if r := revive(func() {
		RegisterVerifier(cross(cur), nsPrefix+"ver_over", "fp", "groth16", "bn254", 1, "", maxVer+"x")
	}); r == nil {
		t.Fatalf("expected oversized version panic")
	}
	if r := revive(func() {
		RegisterVerifier(cross(cur), nsPrefix+"pub_over", "fp", "groth16", "bn254", MaxPublicInputs+1, "", "v1")
	}); r == nil {
		t.Fatalf("expected oversized publicInputs panic")
	}

	// Pagination: valid pages & invalid offsets/limits.
	p1 := ListVerifiersPaged(0, 1)
	p2 := ListVerifiersPaged(1, 1)
	if !strings.Contains(p1, "#1:") || !strings.Contains(p2, "#2:") {
		t.Fatalf("pagination mismatch: p1=%q p2=%q", p1, p2)
	}
	if ListVerifiersPaged(10, 1) != "" {
		t.Fatalf("expected empty out-of-range page")
	}
	if ListVerifiersPaged(-1, 1) != "" {
		t.Fatalf("expected empty for negative offset")
	}
	if ListVerifiersPaged(0, 0) != "" {
		t.Fatalf("expected empty for zero limit")
	}
	if ListVerifiersPaged(0, MaxPageSize+1) != "" {
		t.Fatalf("expected empty for oversized limit")
	}
	if !strings.Contains(Render(""), "#2:") {
		t.Fatalf("Render missing #2")
	}
}

func TestRegistryWorstCaseGas(cur realm, t *testing.T) {
	pub := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(pub))
	ns := "gno.land/r/" + pub.String() + "/"
	// Fill up to MaxRecordsPerPublisher and verify 33rd is rejected.
	for i := 0; i < MaxRecordsPerPublisher; i++ {
		RegisterVerifier(cross(cur), ns+"v"+string(rune('a'+i/26))+string(rune('a'+i%26)), "fp", "groth16", "bn254", 1, "meta", "v1")
	}
	if r := revive(func() {
		RegisterVerifier(cross(cur), ns+"overflow", "fp", "groth16", "bn254", 1, "meta", "v1")
	}); r == nil {
		t.Fatalf("expected per-publisher cap panic")
	}
	_ = ListVerifiersPaged(0, MaxPageSize)
}
