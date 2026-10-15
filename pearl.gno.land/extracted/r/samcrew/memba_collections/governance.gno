package memba_collections

import (
	"chain"
)

// ── Market registry (DRAIN KEY) ─────────────────────────────────────────────

// RegisterMarket authorizes a marketplace realm to call MarketTransfer. This
// is a drain key: platformAdmin only, event-logged.
func RegisterMarket(cur realm, market address) {
	assertPlatformAdmin()
	registeredMarkets.Set(market.String(), true)
	chain.Emit("MarketRegistered", "market", market.String())
}

func UnregisterMarket(cur realm, market address) {
	assertPlatformAdmin()
	registeredMarkets.Remove(market.String())
	chain.Emit("MarketUnregistered", "market", market.String())
}

// ── Pause ────────────────────────────────────────────────────────────────────

func assertPauserOrAdmin() {
	cr := caller()
	if cr != pauser && cr != platformAdmin {
		panic("pauser or platform admin only")
	}
}

// Pause halts the whole registry. The fast pauser role OR platformAdmin.
func Pause(cur realm) {
	assertPauserOrAdmin()
	paused = true
	chain.Emit("Paused")
}

func Unpause(cur realm) {
	assertPauserOrAdmin()
	paused = false
	chain.Emit("Unpaused")
}

// PauseCollection / UnpauseCollection pause a single collection. Collection
// admin, pauser, or platformAdmin.
func PauseCollection(cur realm, id string) {
	c := mustGet(id)
	cr := caller()
	if cr != c.admin && cr != pauser && cr != platformAdmin {
		panic("not authorized to pause collection")
	}
	c.paused = true
	chain.Emit("CollectionPaused", "collectionID", id)
}

func UnpauseCollection(cur realm, id string) {
	c := mustGet(id)
	cr := caller()
	if cr != c.admin && cr != pauser && cr != platformAdmin {
		panic("not authorized to unpause collection")
	}
	c.paused = false
	chain.Emit("CollectionUnpaused", "collectionID", id)
}

func IsPaused() bool { return paused }

// ── Platform params (each change individually event-logged, E-1) ─────────────

func SetCreateFee(cur realm, newFee int64) {
	assertPlatformAdmin()
	if newFee < 0 {
		panic("negative fee")
	}
	old := createFee
	createFee = newFee
	chain.Emit("CreateFeeSet", "old", itoa(old), "new", itoa(newFee), "block", itoa(chainHeight()))
}

func SetPrimaryFeeBPS(cur realm, bps int64) {
	assertPlatformAdmin()
	if bps < 0 || bps > MaxPrimaryFeeBPS {
		panic("primaryFeeBPS out of range")
	}
	old := primaryFeeBPS
	primaryFeeBPS = bps
	chain.Emit("PrimaryFeeBPSSet", "old", itoa(old), "new", itoa(bps), "block", itoa(chainHeight()))
}

func SetMaxCreatorRoyaltyBPS(cur realm, bps int64) {
	assertPlatformAdmin()
	if bps < 0 || bps > MaxRoyaltyBPS {
		panic("maxCreatorRoyaltyBPS out of range")
	}
	old := maxCreatorRoyaltyBPS
	maxCreatorRoyaltyBPS = bps
	chain.Emit("MaxCreatorRoyaltyBPSSet", "old", itoa(old), "new", itoa(bps), "block", itoa(chainHeight()))
}

func SetFeeRecipient(cur realm, newRecip address) {
	assertPlatformAdmin()
	if newRecip == "" {
		panic("empty fee recipient")
	}
	old := feeRecipient
	feeRecipient = newRecip
	chain.Emit("FeeRecipientSet", "old", old.String(), "new", newRecip.String(), "block", itoa(chainHeight()))
}

func AllowDenom(cur realm, denom string) {
	assertPlatformAdmin()
	if denom == "" {
		panic("empty denom")
	}
	allowedDenoms.Set(denom, true)
	chain.Emit("DenomAllowed", "denom", denom, "block", itoa(chainHeight()))
}

func DisallowDenom(cur realm, denom string) {
	assertPlatformAdmin()
	allowedDenoms.Remove(denom)
	chain.Emit("DenomDisallowed", "denom", denom, "block", itoa(chainHeight()))
}

func SetPauser(cur realm, newPauser address) {
	assertPlatformAdmin()
	old := pauser
	pauser = newPauser
	chain.Emit("PauserSet", "old", old.String(), "new", newPauser.String())
}

// ── Platform admin 2-step transfer ──────────────────────────────────────────

func TransferPlatformAdmin(cur realm, newAdmin address) {
	assertPlatformAdmin()
	pendingPlatformAdmin = newAdmin
	chain.Emit("PlatformAdminTransferred", "pending", newAdmin.String())
}

func AcceptPlatformAdmin(cur realm) {
	if caller() != pendingPlatformAdmin {
		panic("not pending platform admin")
	}
	platformAdmin = pendingPlatformAdmin
	pendingPlatformAdmin = ""
	chain.Emit("PlatformAdminAccepted", "admin", platformAdmin.String())
}

// ForceSetCollectionAdmin is the platformAdmin break-glass for a lost or
// compromised creator key. Event-logged.
func ForceSetCollectionAdmin(cur realm, id string, newAdmin address) {
	assertPlatformAdmin()
	c := mustGet(id)
	c.admin = newAdmin
	c.pendingAdmin = ""
	chain.Emit("ForceAdminSet", "collectionID", id, "newAdmin", newAdmin.String())
}

// ── Extensible per-collection metadata (DAO badge / flags) ──────────────────

func SetCollectionMeta(cur realm, id, key, value string) {
	assertPlatformAdmin()
	c := mustGet(id)
	c.meta.Set(key, value)
	chain.Emit("CollectionMetaSet", "collectionID", id, "key", key, "value", value)
}

func GetCollectionMeta(id, key string) string {
	c := mustGet(id)
	if v, ok := c.meta.Get(key); ok {
		return v.(string)
	}
	return ""
}
