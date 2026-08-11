package manager

import "gno.land/p/nt/ufmt/v0"

// RequireUnlockedConfigRole rejects role ids whose configuration is locked.
// Use this before emitting LabelRole metadata from a realm.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L226-L230
func RequireUnlockedConfigRole(role RoleId) {
	if role == AdminRole || role == PublicRole {
		panic(errorWithDetails(errAccessManagerLockedRole, ufmt.Sprintf("role %d is locked", role)))
	}
}
