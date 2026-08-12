// Package bond is the create-bond policy for gnomemepad — separate from pad
// so promo schedules can change without redeploying the pad realm.
//
// Pad calls CurrentBondUgnot() at Create time. This package owns:
//   - normal bond (default 2 GNOT)
//   - promo bond (default ~$20 in ugnot at a fixed GNOT rate, admin-adjustable)
//   - 10-day window OR admin EndPromo → back to normal
//
// USD is not on-chain: promo amount is ugnot. Admin sets PromoBondUgnot to
// approximate $20 (e.g. at $1/GNOT → 20e6 ugnot; at $0.5/GNOT → 40e6).
package bond

import (
	"chain"
	"strconv"
	"time"
)

const (
	DenomUgnot = "ugnot"

	// Defaults (ugnot, 1 GNOT = 1e6 ugnot)
	DefaultNormalBondUgnot int64 = 2_000_000  // 2 GNOT
	DefaultPromoBondUgnot  int64 = 20_000_000 // 20 GNOT ≈ $20 if GNOT ≈ $1
	DefaultPromoDuration   int64 = 10 * 24 * 60 * 60 // 10 days (seconds)

	// Status for UI
	StatusNormal = 0
	StatusPromo  = 1
)

var (
	inited bool
	admin  address

	normalBondUgnot int64
	promoBondUgnot  int64
	// promo: active while time.Now().Unix() < promoEndsAt and !promoEnded
	promoEndsAt int64
	promoEnded  bool // admin force-end (or auto after window)
	promoStartedAt int64
)

// Init sets admin (deploy EOA) and default bond amounts. Call once.
func Init(cur realm) {
	if inited {
		panic("bond: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("bond: EOA only")
	}
	admin = cur.Previous().Address()
	normalBondUgnot = DefaultNormalBondUgnot
	promoBondUgnot = DefaultPromoBondUgnot
	promoEndsAt = 0
	promoEnded = true
	promoStartedAt = 0
	inited = true
	chain.Emit("Init", "admin", admin.String())
}

func requireInit() {
	if !inited {
		panic("bond: call Init first")
	}
}

func requireAdmin(cur realm) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("bond: EOA only")
	}
	if cur.Previous().Address() != admin {
		panic("bond: not admin")
	}
}

// Admin returns the admin (deploy) address.
func Admin() string {
	requireInit()
	return admin.String()
}

// TransferAdmin rotates admin (current admin only).
func TransferAdmin(cur realm, newAdmin address) {
	requireAdmin(cur)
	if !newAdmin.IsValid() {
		panic("bond: invalid address")
	}
	old := admin
	admin = newAdmin
	chain.Emit("TransferAdmin", "from", old.String(), "to", newAdmin.String())
}

// IsPromoActive reports whether the promo window is currently in force.
func IsPromoActive() bool {
	if !inited || promoEnded || promoEndsAt <= 0 {
		return false
	}
	now := time.Now().Unix()
	if now >= promoEndsAt {
		return false
	}
	return true
}

// CurrentBondUgnot is the create bond pad must require (cross-safe read).
// Pad: if sent < CurrentBondUgnot() → panic underpaid.
func CurrentBondUgnot() int64 {
	requireInit()
	if IsPromoActive() {
		return promoBondUgnot
	}
	return normalBondUgnot
}

// NormalBondUgnot returns the post-promo / default bond.
func NormalBondUgnot() int64 {
	requireInit()
	return normalBondUgnot
}

// PromoBondUgnot returns the promo-period bond amount (may be inactive).
func PromoBondUgnot() int64 {
	requireInit()
	return promoBondUgnot
}

// PromoEndsAt returns unix end of promo (0 if never started).
func PromoEndsAt() int64 {
	requireInit()
	return promoEndsAt
}

// PromoSecondsLeft returns remaining promo seconds (0 if inactive).
func PromoSecondsLeft() int64 {
	if !IsPromoActive() {
		return 0
	}
	left := promoEndsAt - time.Now().Unix()
	if left < 0 {
		return 0
	}
	return left
}

// Status: 0=normal 1=promo active.
func Status() int {
	if IsPromoActive() {
		return StatusPromo
	}
	return StatusNormal
}

// BondInfo: status|currentUgnot|normalUgnot|promoUgnot|endsAt|secondsLeft|admin
func BondInfo() string {
	requireInit()
	st := Status()
	return strconv.Itoa(st) + "|" +
		strconv.FormatInt(CurrentBondUgnot(), 10) + "|" +
		strconv.FormatInt(normalBondUgnot, 10) + "|" +
		strconv.FormatInt(promoBondUgnot, 10) + "|" +
		strconv.FormatInt(promoEndsAt, 10) + "|" +
		strconv.FormatInt(PromoSecondsLeft(), 10) + "|" +
		admin.String()
}

// StartPromo begins a promo window from now.
// promoUgnot: bond during promo (e.g. 20e6 ≈ $20 at $1/GNOT). 0 → keep current promoBondUgnot.
// durationSec: window length. 0 → DefaultPromoDuration (10 days).
func StartPromo(cur realm, promoUgnot, durationSec int64) {
	requireAdmin(cur)
	if promoUgnot < 0 {
		panic("bond: promoUgnot must be non-negative")
	}
	if promoUgnot > 0 {
		promoBondUgnot = promoUgnot
	}
	if promoBondUgnot <= 0 {
		panic("bond: set promo bond amount first")
	}
	if durationSec <= 0 {
		durationSec = DefaultPromoDuration
	}
	now := time.Now().Unix()
	promoStartedAt = now
	promoEndsAt = now + durationSec
	promoEnded = false
	chain.Emit("StartPromo",
		"promoUgnot", strconv.FormatInt(promoBondUgnot, 10),
		"endsAt", strconv.FormatInt(promoEndsAt, 10),
		"durationSec", strconv.FormatInt(durationSec, 10),
	)
}

// EndPromo forces normal bond immediately (deploy admin).
func EndPromo(cur realm) {
	requireAdmin(cur)
	promoEnded = true
	// keep promoEndsAt for history
	chain.Emit("EndPromo",
		"at", strconv.FormatInt(time.Now().Unix(), 10),
		"normalUgnot", strconv.FormatInt(normalBondUgnot, 10),
	)
}

// SetNormalBond updates the post-promo bond (default 2 GNOT).
func SetNormalBond(cur realm, ugnot int64) {
	requireAdmin(cur)
	if ugnot <= 0 {
		panic("bond: normal bond must be positive")
	}
	normalBondUgnot = ugnot
	chain.Emit("SetNormalBond", "ugnot", strconv.FormatInt(ugnot, 10))
}

// SetPromoBond updates promo amount without restarting the clock.
// Use to re-target ~$20 when GNOT price moves during the window.
func SetPromoBond(cur realm, ugnot int64) {
	requireAdmin(cur)
	if ugnot <= 0 {
		panic("bond: promo bond must be positive")
	}
	promoBondUgnot = ugnot
	chain.Emit("SetPromoBond", "ugnot", strconv.FormatInt(ugnot, 10))
}

// ExtendPromo adds seconds to the current end (or starts from now if inactive).
func ExtendPromo(cur realm, extraSec int64) {
	requireAdmin(cur)
	if extraSec <= 0 {
		panic("bond: extraSec must be positive")
	}
	now := time.Now().Unix()
	if !IsPromoActive() {
		// restart promo with current promoBondUgnot
		promoStartedAt = now
		promoEndsAt = now + extraSec
		promoEnded = false
	} else {
		promoEndsAt += extraSec
		promoEnded = false
	}
	chain.Emit("ExtendPromo",
		"endsAt", strconv.FormatInt(promoEndsAt, 10),
		"extraSec", strconv.FormatInt(extraSec, 10),
	)
}
