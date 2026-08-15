package errcollectionv2

// Debug-only: faithfully replicates g7's actual GetApproved behavior
// (errors when nothing is individually approved, not just an empty
// return) AND its storage shape (avl.Tree, matching grc721v2.BasicNFT
// and testcollectionv2 — NOT a plain built-in map, to rule out a
// simulate-vs-qeval discrepancy specific to map storage as a confound).

import (
	"errors"

	"gno.land/p/nt/avl/v0"
)

var (
	owners            = avl.NewTree() // tid -> address
	operatorApprovals = avl.NewTree() // "owner|operator" -> bool
)

var errNoApproval = errors.New("token id not approved for anyone")

func Name() string { return "ErrCollection" }

func Mint(cur realm, to address, tid string) {
	owners.Set(tid, to)
}

func OwnerOf(tid string) (address, error) {
	owner, _ := owners.Get(tid).(address)
	return owner, nil
}

func TokenURI(tid string) (string, error) {
	return "", nil
}

// GetApproved errors when nothing is individually approved — matches g7's
// real behavior exactly, unlike testcollectionv2's silent empty return.
func GetApproved(tid string) (address, error) {
	return "", errNoApproval
}

func operatorKey(owner, operator address) string {
	return owner.String() + "|" + operator.String()
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	caller := cur.Previous().Address()
	key := operatorKey(caller, operator)
	if approved {
		operatorApprovals.Set(key, true)
	} else {
		operatorApprovals.Remove(key)
	}
}

func IsApprovedForAll(owner, operator address) bool {
	return operatorApprovals.Has(operatorKey(owner, operator))
}

func TransferFrom(cur realm, from, to address, tid string) {
	caller := cur.Previous().Address()
	owner, _ := owners.Get(tid).(address)
	if caller != owner && !IsApprovedForAll(owner, caller) {
		panic("not authorized")
	}
	owners.Set(tid, to)
}
