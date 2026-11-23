package sealedpost

import (
	"crypto/bech32"
	"strings"
	"testing"

	"gno.land/p/g1gu8mdvjg8l5wj2ytknhs7pmyu0rmeclyvvlsd8/commitreveal"
)

// testAddr derives a deterministic valid bech32 address from a short
// name (same scheme as gno.land/p/nt/testutils, replicated here so the
// tests stay self-contained within this workspace).
func testAddr(name string) address {
	raw := []byte("____________________")
	copy(raw[:], name)
	converted, err := bech32.ConvertBits(raw, 8, 5, true)
	if err != nil {
		panic(err)
	}
	enc, err := bech32.Encode("g", converted)
	if err != nil {
		panic(err)
	}
	return address(enc)
}

var (
	alice = testAddr("alice")
	bob   = testAddr("bob")
)

// mustPanic fails the test if f does not panic. Panics raised inside a
// realm function invoked through cross() surface as cross-realm aborts,
// which recover() cannot catch; the revive builtin catches them instead
// (same approach as gno.land/p/nt/uassert).
func mustPanic(t *testing.T, what string, f func()) {
	t.Helper()
	if abort := revive(f); abort == nil {
		t.Fatalf("expected panic (%s), got none", what)
	}
}

// reset clears all realm state and sets the chain height. Note: the
// caller is NOT set here — testing.SetRealm only takes effect on the
// realm chain captured by the calling frame, so every test must call
// testing.SetRealm(testing.NewUserRealm(alice)) in its own body (the
// pattern used by the official examples). Chain height, in contrast, is
// machine-global and can be set from this helper.
func reset(height int64) {
	capsules = nil
	testing.SetHeight(height)
}

const (
	secretPayload = "hello future"
	secretSalt    = "pepper"
)

func TestSealAndRevealHappyPath(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	commitment := commitreveal.Commit(secretPayload, secretSalt)

	id := Seal(cross(cur), "First capsule", commitment, 150, "")
	if id != "1" {
		t.Fatalf("Seal returned id %q, want %q", id, "1")
	}
	if len(capsules) != 1 {
		t.Fatalf("got %d capsules, want 1", len(capsules))
	}
	c := capsules[0]
	if c.Author != alice {
		t.Fatalf("author = %s, want %s", c.Author, alice)
	}
	if c.Recipient != address("") {
		t.Fatalf("recipient = %s, want zero address", c.Recipient)
	}
	if c.CreatedHeight != 100 || c.UnlockHeight != 150 {
		t.Fatalf("heights = created %d unlock %d, want 100/150", c.CreatedHeight, c.UnlockHeight)
	}
	if c.Revealed {
		t.Fatal("capsule must start unrevealed")
	}

	// Exactly at the unlock height the reveal is accepted.
	testing.SetHeight(150)
	res := Reveal(cross(cur), 1, secretPayload, secretSalt)
	if !strings.Contains(res, "revealed") {
		t.Fatalf("Reveal returned %q", res)
	}
	if !c.Revealed || c.RevealedText != secretPayload {
		t.Fatalf("after reveal: revealed=%v text=%q", c.Revealed, c.RevealedText)
	}

	// Render shows the revealed text on both pages.
	if out := Render(""); !strings.Contains(out, "First capsule") || !strings.Contains(out, secretPayload) {
		t.Fatalf("home render missing title or revealed text:\n%s", out)
	}
	if out := Render("capsule/1"); !strings.Contains(out, secretPayload) {
		t.Fatalf("capsule render missing revealed text:\n%s", out)
	}
}

func TestRevealTooEarly(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	commitment := commitreveal.Commit(secretPayload, secretSalt)
	Seal(cross(cur), "Too early", commitment, 200, "")

	testing.SetHeight(199)
	mustPanic(t, "reveal before unlock height", func() {
		Reveal(cross(cur), 1, secretPayload, secretSalt)
	})
	if capsules[0].Revealed {
		t.Fatal("capsule must stay sealed after an early reveal attempt")
	}
}

func TestRevealWrongPayloadOrSalt(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	commitment := commitreveal.Commit(secretPayload, secretSalt)
	Seal(cross(cur), "Wrong secrets", commitment, 120, "")
	testing.SetHeight(120)

	mustPanic(t, "wrong payload", func() {
		Reveal(cross(cur), 1, "hello futur3", secretSalt)
	})
	mustPanic(t, "wrong salt", func() {
		Reveal(cross(cur), 1, secretPayload, "pepp3r")
	})
	if capsules[0].Revealed {
		t.Fatal("capsule must stay sealed after failed reveals")
	}

	// The correct pair still works afterwards.
	Reveal(cross(cur), 1, secretPayload, secretSalt)
	if !capsules[0].Revealed {
		t.Fatal("capsule must be revealed after the correct reveal")
	}
}

func TestDoubleReveal(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	commitment := commitreveal.Commit(secretPayload, secretSalt)
	Seal(cross(cur), "Twice", commitment, 110, "")
	testing.SetHeight(110)

	Reveal(cross(cur), 1, secretPayload, secretSalt)
	mustPanic(t, "double reveal", func() {
		Reveal(cross(cur), 1, secretPayload, secretSalt)
	})
}

func TestSealInvalidCommitment(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	mustPanic(t, "garbage commitment", func() {
		Seal(cross(cur), "Bad", "not-a-commitment", 150, "")
	})
	mustPanic(t, "uppercase commitment", func() {
		Seal(cross(cur), "Bad", "ABED8DAA81DD1A51341475821D206A2C5AC0CB28A104884FCC3BDCBDBD29DDAA", 150, "")
	})
	if len(capsules) != 0 {
		t.Fatal("no capsule may be stored for an invalid commitment")
	}
}

func TestSealInvalidRecipient(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	commitment := commitreveal.Commit(secretPayload, secretSalt)
	mustPanic(t, "invalid recipient", func() {
		Seal(cross(cur), "Bad recipient", commitment, 150, "not-an-address")
	})

	id := Seal(cross(cur), "For bob", commitment, 150, bob.String())
	if id != "1" {
		t.Fatalf("Seal returned id %q, want %q", id, "1")
	}
	if capsules[0].Recipient != bob {
		t.Fatalf("recipient = %s, want %s", capsules[0].Recipient, bob)
	}
}

func TestSealUnlockMustBeFuture(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	commitment := commitreveal.Commit(secretPayload, secretSalt)
	mustPanic(t, "unlock height == current height", func() {
		Seal(cross(cur), "Now", commitment, 100, "")
	})
	mustPanic(t, "unlock height in the past", func() {
		Seal(cross(cur), "Past", commitment, 99, "")
	})
}

func TestSealTitleTooLong(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	commitment := commitreveal.Commit(secretPayload, secretSalt)
	mustPanic(t, "title over 80 chars", func() {
		Seal(cross(cur), strings.Repeat("x", 81), commitment, 150, "")
	})
}

func TestRevealNonexistentCapsule(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	mustPanic(t, "reveal of unknown capsule", func() {
		Reveal(cross(cur), 99, secretPayload, secretSalt)
	})
	if out := Render("capsule/99"); !strings.Contains(out, "not found") {
		t.Fatalf("render of unknown capsule should say not found:\n%s", out)
	}
}

func TestRenderSealedCountdown(cur realm, t *testing.T) {
	reset(100)
	testing.SetRealm(testing.NewUserRealm(alice))
	commitment := commitreveal.Commit(secretPayload, secretSalt)
	Seal(cross(cur), "Countdown", commitment, 150, "")

	out := Render("")
	if !strings.Contains(out, "Countdown") || !strings.Contains(out, "50 blocks to go") {
		t.Fatalf("home render missing countdown:\n%s", out)
	}
	if strings.Contains(out, secretPayload) {
		t.Fatal("home render must not leak the secret payload before reveal")
	}
}
