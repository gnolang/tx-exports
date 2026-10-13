package bolo

import (
	"chain"

	"gno.land/p/nt/seqid/v0"
)

// The paths Bolo's addresses derive from. pkgPath is this realm's own; a test
// checks it against the realm.
const (
	pkgPath      = "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0"
	registryPath = "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo"
	slashedPath  = "slashed" // where slashed bonds go; nothing ever spends it (INV-8)
)

// escrowPath and bondPath are a campaign's sub-paths (API §1): one escrow and one
// bond address per campaign, so a bug in one campaign can't spend another's.
func escrowPath(id seqid.ID) string { return "c/" + idString(id) }

func bondPath(id seqid.ID) string { return "b/" + idString(id) }

// escrowSub and bondSub are the only places Bolo derives a sub-realm, and so the
// only way to a banker for a campaign's addresses (API C9, INV-8, INV-18). They
// take the stored campaign itself, never an ID: an ID parsed from an argument has
// to find its campaign first.
func escrowSub(cur realm, c *campaign) realm { return cur.Sub(escrowPath(c.id)) }

func bondSub(cur realm, c *campaign) realm { return cur.Sub(bondPath(c.id)) }

// The same addresses for queries and Render, which have no cur, and the other
// addresses Bolo never pays a campaign to (API §1).
func escrowAddr(id seqid.ID) address { return chain.DerivePkgSubAddr(pkgPath, escrowPath(id)) }

func bondAddr(id seqid.ID) address { return chain.DerivePkgSubAddr(pkgPath, bondPath(id)) }

func slashedAddr() address { return chain.DerivePkgSubAddr(pkgPath, slashedPath) }

func realmAddr() address { return chain.PackageAddress(pkgPath) }

func depositAddr() address { return chain.DeriveStorageDepositAddr(pkgPath) }

func registryAddr() address { return chain.PackageAddress(registryPath) }

func registryDepositAddr() address { return chain.DeriveStorageDepositAddr(registryPath) }
