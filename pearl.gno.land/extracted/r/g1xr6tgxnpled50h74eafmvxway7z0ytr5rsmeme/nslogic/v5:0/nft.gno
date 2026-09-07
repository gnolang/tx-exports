package nslogic

import (
	"strings"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// This realm only exposes the WRITE side of the GRC-721 surface. Reads
// (BalanceOf, OwnerOf, TokenURI, GetApproved, IsApprovedForAll, and
// every listing/status/profile query) have no authorization check to
// perform and are served directly by nsdata — no reason to duplicate
// them here.

func isDomainToken(tid string) bool {
	return strings.HasPrefix(tid, "*")
}

// isTokenValid checks the underlying domain/name's expiry via nsdata's
// own validity reads — the anti-scam pattern (an expired name must not
// be sellable) enforced at the transfer boundary, not just at read time.
func isTokenValid(tid string) bool {
	if isDomainToken(tid) {
		return nsdata.IsDomainValid(tid[1:])
	}
	label, domainLabel := splitTokenID(tid)
	return nsdata.IsNameValid(label, domainLabel)
}

func Approve(cur realm, to address, tid string) {
	assertNoSend(cur)
	if isDomainToken(tid) {
		panic("nslogic: domains are project-owned and non-transferable")
	}
	if !isTokenValid(tid) {
		panic("nslogic: cannot approve an expired token")
	}
	caller := cur.Previous().Address()
	if err := nsdata.RawApprove(cross(cur), caller, to, tid); err != nil {
		panic(err)
	}
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	if err := nsdata.RawSetApprovalForAll(cross(cur), caller, operator, approved); err != nil {
		panic(err)
	}
}

// TransferFrom / SafeTransferFrom are the actual enforcement point for
// both (a) the anti-scam pattern — blocking transfer of an expired token
// closes off third-party marketplace sales without blocking the owner's
// own ability to reclaim by renewing (renewal never goes through these)
// — and (b) the domains-are-never-transferable policy: blocking it here,
// not just at RegisterDomain, is what actually closes the loophole.
// (ReassignDomain in domain.gno is the deliberate admin-only exception;
// see its comment.)
func TransferFrom(cur realm, from, to address, tid string) {
	assertNoSend(cur)
	if isDomainToken(tid) {
		panic("nslogic: domains are project-owned and non-transferable")
	}
	if !isTokenValid(tid) {
		panic("nslogic: cannot transfer an expired token")
	}
	label, domainLabel := splitTokenID(tid)
	caller := cur.Previous().Address()
	// A free-tier record has no GRC-721 token to move, so the token-layer
	// transfer would fail; the vault exposes a record-only path for it.
	if !nsdata.IsNameNFT(label, domainLabel) {
		if caller != from || nsdata.GetNameOwner(label, domainLabel) != caller {
			panic("nslogic: restricted to name owner")
		}
		if err := nsdata.TransferRecordOwner(cross(cur), label, domainLabel, to); err != nil {
			panic(err)
		}
		return
	}
	if err := nsdata.RawTransferNFT(cross(cur), caller, from, to, tid); err != nil {
		panic(err)
	}
}

// nsdata only exposes one raw transfer primitive (RawTransferNFT, backed
// by grc721's plain TransferFrom) — the safe-receiver-interface check
// grc721's SafeTransferFrom adds doesn't carry much weight for a
// name-service NFT, so both entry points converge on the same path here.
func SafeTransferFrom(cur realm, from, to address, tid string) {
	TransferFrom(cur, from, to, tid)
}
