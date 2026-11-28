package deeds

import (
	"crypto/bech32"
	"strings"
	"testing"
)

// testAddress builds a deterministic test address from a short name.
// Same construction as gno.land/p/nt/testutils/v0.TestAddress, inlined
// here so the test suite has no external package dependency (the gno
// toolchain cannot fetch gno.land packages from this VM — its HTTP
// client bypasses the egress proxy).
func testAddress(name string) address {
	if len(name) > 20 {
		panic("address name cannot be greater than 20 bytes")
	}
	addr := []byte("____________________")
	copy(addr[:], name)
	converted, err := bech32.ConvertBits(addr, 8, 5, true)
	if err != nil {
		panic(err)
	}
	enc, err := bech32.Encode("g", converted)
	if err != nil {
		panic(err)
	}
	return address(enc)
}

// expectPanic runs f and fails the test if f does not panic.
func expectPanic(t *testing.T, f func()) {
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic, got none")
		}
	}()
	f()
}

func TestRegisterAndLogDeed(t *testing.T) {
	// NOTE: gno test shares realm state across tests in one run, so
	// assert deltas, not absolute totals.
	agentsBefore := len(agentList)
	deedsBefore := len(deedList)
	alice := testAddress("alice-reg")
	registerAgent(alice, "AliceBot", "Research agent")
	if len(agentList) != agentsBefore+1 {
		t.Fatalf("expected %d agents, got %d", agentsBefore+1, len(agentList))
	}
	id := logDeed(alice, "Wrote market brief", "sha256:abc123")
	if id != deedsBefore+1 {
		t.Fatalf("expected deed id %d, got %d", deedsBefore+1, id)
	}
	if agents[alice].DeedCount != 1 {
		t.Fatalf("expected deed count 1, got %d", agents[alice].DeedCount)
	}
	got := Render("")
	for _, want := range []string{"AliceBot", "Wrote market brief", "sha256:abc123", alice.String(), stats()} {
		if !strings.Contains(got, want) {
			t.Fatalf("expected render to contain %q", want)
		}
	}
}

func TestDuplicateRegisterPanics(t *testing.T) {
	alice := testAddress("alice-dup")
	registerAgent(alice, "AliceBot", "Research agent")
	expectPanic(t, func() {
		registerAgent(alice, "AliceBot2", "Second try")
	})
}

func TestInvalidInputsPanic(t *testing.T) {
	alice := testAddress("alice-bad")
	expectPanic(t, func() { registerAgent(alice, "", "empty name") })
	expectPanic(t, func() { registerAgent(alice, strings.Repeat("x", 65), "name too long") })
	registerAgent(alice, "AliceBot", "ok")
	expectPanic(t, func() { logDeed(alice, "", "sha256:abc") })
	expectPanic(t, func() { logDeed(alice, "title", "") })
}

func TestLogDeedUnregisteredPanics(t *testing.T) {
	ghost := testAddress("ghost")
	expectPanic(t, func() { logDeed(ghost, "I do not exist", "sha256:abc") })
}

func TestAttestFlow(t *testing.T) {
	attBefore := len(attestations)
	alice := testAddress("alice-att")
	bob := testAddress("bob-att")
	registerAgent(alice, "AliceBot", "Research agent")
	registerAgent(bob, "BobBot", "Review agent")
	id := logDeed(alice, "Wrote market brief", "sha256:abc123")

	attest(bob, id, "Verified the brief against sources")
	if deeds[id].Attestations != 1 {
		t.Fatalf("expected 1 attestation on deed, got %d", deeds[id].Attestations)
	}
	if agents[alice].Attestations != 1 {
		t.Fatalf("expected 1 attestation for alice, got %d", agents[alice].Attestations)
	}

	// Same attestor cannot attest the same deed twice.
	expectPanic(t, func() { attest(bob, id, "again") })
	// Cannot attest your own deed.
	expectPanic(t, func() { attest(alice, id, "self praise") })
	// Unknown deed.
	expectPanic(t, func() { attest(bob, 999, "ghost deed") })
	// Unregistered attestor.
	ghost := testAddress("ghost-att")
	expectPanic(t, func() { attest(ghost, id, "who am I") })

	if len(attestations) != attBefore+1 {
		t.Fatalf("expected %d attestations total, got %d", attBefore+1, len(attestations))
	}
	got := Render("")
	for _, want := range []string{"AliceBot", "BobBot", "Wrote market brief", stats()} {
		if !strings.Contains(got, want) {
			t.Fatalf("expected render to contain %q, got:\n%s", want, got)
		}
	}
}

func TestTopAgentsOrdering(t *testing.T) {
	alice := testAddress("alice-top")
	bob := testAddress("bob-top")
	carol := testAddress("carol-top")
	dave := testAddress("dave-top")
	registerAgent(alice, "AliceBot", "Research agent")
	registerAgent(bob, "BobBot", "Review agent")
	registerAgent(carol, "CarolBot", "Checker agent")
	registerAgent(dave, "DaveBot", "Checker agent")
	d1 := logDeed(alice, "Brief one", "sha256:111")
	d2 := logDeed(alice, "Brief two", "sha256:222")
	d3 := logDeed(bob, "Review one", "sha256:333")
	attest(carol, d1, "good")
	attest(dave, d1, "good")
	attest(carol, d3, "good")
	attest(dave, d2, "good")
	// Alice: 3 attestations, 2 deeds. Bob: 1 attestation, 1 deed.
	top := topAgents()
	ia := strings.Index(top, "AliceBot")
	ib := strings.Index(top, "BobBot")
	if ia < 0 || ib < 0 || ia > ib {
		t.Fatalf("expected AliceBot before BobBot in top list, got:\n%s", top)
	}
	if !strings.Contains(top, "3 attestations") {
		t.Fatalf("expected AliceBot with 3 attestations, got:\n%s", top)
	}
}

func TestCrossingCallerWiring(cur realm, t *testing.T) {
	// Proves the crossing functions pick up the real caller via
	// unsafe.PreviousRealm(): the test sets the caller realm to zoe.
	zoe := testAddress("zoe-cross")
	testing.SetRealm(testing.NewUserRealm(zoe))
	RegisterAgent(cross(cur), "ZoeBot", "Crossing test agent")
	got := Render("")
	if !strings.Contains(got, "ZoeBot") || !strings.Contains(got, zoe.String()) {
		t.Fatalf("expected render to contain ZoeBot and her address, got:\n%s", got)
	}
	id := LogDeed(cross(cur), "Crossing deed", "sha256:cross")
	if id <= 0 {
		t.Fatalf("expected a positive deed id via crossing call, got %d", id)
	}
	if deeds[id].Title != "Crossing deed" {
		t.Fatalf("expected deed title %q, got %q", "Crossing deed", deeds[id].Title)
	}
}
