package errcollection

// Debug-only: faithfully replicates g7's actual GetApproved behavior
// (errors when nothing is individually approved, not just an empty
// return) — testcollectionv2 does NOT do this, which means the earlier
// "throwaway adapter" test never actually exercised the same code path
// as the real bug.

import (
	"errors"
)

var (
	owners            = map[string]address{}
	operatorApprovals = map[string]bool{}
)

var errNoApproval = errors.New("token id not approved for anyone")

func Name() string { return "ErrCollection" }

func Mint(cur realm, to address, tid string) {
	owners[tid] = to
}

func OwnerOf(tid string) (address, error) {
	return owners[tid], nil
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
	if approved {
		operatorApprovals[operatorKey(caller, operator)] = true
	} else {
		delete(operatorApprovals, operatorKey(caller, operator))
	}
}

func IsApprovedForAll(owner, operator address) bool {
	return operatorApprovals[operatorKey(owner, operator)]
}

func TransferFrom(cur realm, from, to address, tid string) {
	caller := cur.Previous().Address()
	owner := owners[tid]
	if caller != owner && !IsApprovedForAll(owner, caller) {
		panic("not authorized")
	}
	owners[tid] = to
}
