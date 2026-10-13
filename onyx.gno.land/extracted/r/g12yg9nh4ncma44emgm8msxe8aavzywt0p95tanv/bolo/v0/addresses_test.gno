package bolo

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/seqid/v0"
)

// TestAddresses: the addresses queries derive are the ones the realm's bankers
// spend from, and each one is distinct (API §1, INV-18).
func TestAddresses(cur realm, t *testing.T) {
	if cur.PkgPath() != pkgPath {
		t.Fatalf("pkgPath is %s, but the realm is %s", pkgPath, cur.PkgPath())
	}
	if realmAddr() != cur.Address() {
		t.Errorf("realmAddr() = %s, the realm is %s", realmAddr(), cur.Address())
	}
	// Each fixed address is the one its role names: the keeper's deposit address
	// for this realm, this realm's "slashed" sub-address, and the package one path
	// up, where the registry lives.
	if depositAddr() != chain.DeriveStorageDepositAddr(cur.PkgPath()) {
		t.Errorf("depositAddr() isn't the realm's storage-deposit address")
	}
	if slashedAddr() != cur.Sub("slashed").Address() {
		t.Errorf("slashedAddr() isn't the realm's slashed sub-address")
	}
	if registryAddr() != chain.PackageAddress(strings.TrimSuffix(cur.PkgPath(), "/v0")) {
		t.Errorf("registryAddr() isn't the registry's, one path up")
	}
	if registryDepositAddr() != chain.DeriveStorageDepositAddr(strings.TrimSuffix(cur.PkgPath(), "/v0")) {
		t.Errorf("registryDepositAddr() isn't the registry's storage-deposit address")
	}
	seen := map[address]string{
		realmAddr():           "the realm",
		slashedAddr():         "slashed",
		depositAddr():         "the storage deposit",
		registryAddr():        "the registry",
		registryDepositAddr(): "the registry's storage deposit",
	}
	if len(seen) != 5 {
		t.Fatalf("realm, slashed, deposit and registry addresses collide")
	}
	for _, id := range []seqid.ID{1, 2, 42, 1 << 63} {
		c := &campaign{id: id}
		if escrowSub(cur, c).Address() != escrowAddr(id) {
			t.Errorf("campaign %d: escrowSub and escrowAddr differ", uint64(id))
		}
		if bondSub(cur, c).Address() != bondAddr(id) {
			t.Errorf("campaign %d: bondSub and bondAddr differ", uint64(id))
		}
		for _, a := range []address{escrowAddr(id), bondAddr(id)} {
			if other, dup := seen[a]; dup {
				t.Errorf("campaign %d: %s is also %s", uint64(id), a, other)
			}
			seen[a] = "campaign " + idString(id)
		}
	}
	// The address for "42" is campaign 42's; "042" names nothing (INV-18).
	id, _ := parseID("42")
	if escrowAddr(id) != escrowAddr(42) {
		t.Errorf("parsed and stored IDs give different escrows")
	}
}
