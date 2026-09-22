package home

import (
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0"
	"gno.land/p/nt/avl/v0"
)

// Test hooks. Realm globals live for the whole test binary, so every test
// that reads Render or Manifest starts from a known tree and a fresh proxy.

// ResetForTest clears all realm state.
func ResetForTest() {
	slots = avl.NewTree()
	rev = 0
	lastHeight = 0
	proxy = upgradeable.New(upgradeable.NewAddrAuthority(Admin))
}

// SeedForTest writes a slot without the authority check.
func SeedForTest(slug, body string) {
	rev++
	slots.Set(slug, &Slot{Body: body, Rev: rev, Height: 0})
}

// ReservedSlugsForTest exposes the reserved names.
func ReservedSlugsForTest() []string { return reservedSlugs }
