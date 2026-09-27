package otc

import (
	"chain"
	"strconv"

	"gno.land/r/nt/grc20reg/v0"
)

// The admin's whole reach (A1). None of these touches an offer or an escrow
// (A3); every one refuses coins (S2) and emits an event.

// AddToken whitelists a token by its grc20reg key, enabled (W2).
func AddToken(cur realm, key string) {
	requireAdmin(cur)
	if grc20reg.Get(key) == nil {
		panic(ErrTokenUnknown)
	}
	if tokens.Has(key) {
		panic(ErrTokenExists)
	}
	if tokens.Size() >= maxTokens {
		panic(ErrTooManyTokens)
	}
	tokens.Set(key, true)
	chain.Emit(EventTokenChanged, "token", key, "enabled", "true")
}

// SetTokenEnabled switches new offers on a token on or off. Open offers on a
// disabled token can still be filled and cancelled (W2).
func SetTokenEnabled(cur realm, key string, enabled bool) {
	requireAdmin(cur)
	if !tokens.Has(key) {
		panic(ErrTokenNotListed)
	}
	tokens.Set(key, enabled)
	chain.Emit(EventTokenChanged, "token", key, "enabled", strconv.FormatBool(enabled))
}

// SetFeeBps sets the default fee for NEW offers (F4, F5).
func SetFeeBps(cur realm, bps int64) {
	requireAdmin(cur)
	requireFee(bps)
	feeBps = bps
	chain.Emit(EventFeeChanged, "fee_bps", strconv.FormatInt(bps, 10))
}

// SetGnomicFee turns the reduced GNOMIC fee on or off and sets it (F6).
func SetGnomicFee(cur realm, enabled bool, bps int64) {
	requireAdmin(cur)
	requireFee(bps)
	gnomicFeeOn = enabled
	gnomicFee = bps
	chain.Emit(EventFeeChanged,
		"gnomic_fee_enabled", strconv.FormatBool(enabled),
		"gnomic_fee_bps", strconv.FormatInt(bps, 10))
}

// SetFeeRecipient changes where fees go.
func SetFeeRecipient(cur realm, to address) {
	requireAdmin(cur)
	if !to.IsValid() {
		panic(ErrBadAddress)
	}
	if to == realmAddr {
		panic(ErrFeeToRealm)
	}
	old := feeRecipient
	feeRecipient = to
	chain.Emit(EventFeeRecipientChanged, "old", old.String(), "new", to.String())
}

// SetPaused blocks or allows new offers and fills. It never blocks Cancel
// (A2, R10).
func SetPaused(cur realm, p bool) {
	requireAdmin(cur)
	paused = p
	chain.Emit(EventPaused, "paused", strconv.FormatBool(p))
}

// TransferAdmin hands the admin role to another address.
func TransferAdmin(cur realm, to address) {
	requireAdmin(cur)
	if !to.IsValid() || to == realmAddr {
		panic(ErrBadAddress)
	}
	old := admin
	admin = to
	chain.Emit(EventAdminChanged, "old", old.String(), "new", to.String())
}

func requireAdmin(cur realm) {
	requireNoCoins()
	if cur.Previous().Address() != admin {
		panic(ErrNotAdmin) // S7
	}
}

func requireFee(bps int64) {
	if bps < 0 || bps > feeCapBps {
		panic(ErrFeeAboveCap)
	}
}
