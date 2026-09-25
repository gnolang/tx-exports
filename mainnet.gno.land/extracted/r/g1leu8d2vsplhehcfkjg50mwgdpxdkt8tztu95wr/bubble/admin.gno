package bubble

// The settings, and who may change them.
//
// admin is whoever deployed the realm (Jae's hotkey signs the addpkg) and is handed to the box's keeper key in the
// same minute ("a token that you control, but admin can be transferred and even destroyed"). An empty admin is
// nobody, permanently: RenounceAdmin is the "destroyed" Jae asked for. After it, every one of these settings moves
// only by a holders' vote (kinds.gno), and the mint goes on under the minter until the holders stop it.
var (
	// admin is Jae's cold key (jarvis room 201, 2026-09-25: "(b) g1ecsu … make sure that even if the hotkey is
	// hacked the g1ecsu can restore"), named here rather than read from OriginCaller at init: the deployer is the
	// hotkey, which holds no power once the realm is up, and a test package or a filetest loads with no deployer
	// at all. The box holds the minter, whose damage the day cap bounds; if the box or the hotkey is ever taken,
	// this key pauses, names another minter, and goes on.
	admin = address("g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6")
	// minter is the box's keeper key, the only address that mints referrals; "" is nobody.
	minter = address("g18dd5mstjqlcg9ngqpg26azeya6wqg7upd9t8xa")
	paused bool // the admin's brake: stops Mint and MintMany, nothing else
	dayCap = 250_000 * one
)

func init() {
	ledger.SetID(tokenID)
	ledger.Mint(premineTo, premine)
	premined = premine
}

func Admin() address  { return admin }
func Minter() address { return minter }
func Paused() bool    { return paused }
func DayCap() int64   { return dayCap }

func mustBeAdmin(cur realm) {
	who := caller(cur)
	if admin == "" {
		panic("bubble: the admin was given up; the holders decide now")
	}
	if who != admin {
		panic("bubble: only the admin")
	}
}

// SetAdmin hands the settings to another address.
func SetAdmin(cur realm, to address) {
	mustBeAdmin(cur)
	if !to.IsValid() {
		panic("bubble: not an address")
	}
	admin = to
}

// RenounceAdmin gives the settings up for good: from here they move only by vote.
func RenounceAdmin(cur realm) {
	mustBeAdmin(cur)
	admin = ""
}

// SetMinter names who mints; "" is nobody (the referral mint stops until a vote names one).
func SetMinter(cur realm, to address) {
	mustBeAdmin(cur)
	if to != "" && !to.IsValid() {
		panic("bubble: not an address")
	}
	minter = to
}

// SetPaused stops the mint, or lets it go on.
func SetPaused(cur realm, on bool) {
	mustBeAdmin(cur)
	paused = on
}

// SetDayCap lowers the daily ceiling. Raising it is the holders' (govern:daycap): the cap is what bounds a stolen
// key, so the key it bounds may not raise it.
func SetDayCap(cur realm, n int64) {
	mustBeAdmin(cur)
	if n < 0 || n > dayCap {
		panic("bubble: the admin can only lower the day cap; raising it is a vote")
	}
	dayCap = n
}
