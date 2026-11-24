package heirloom

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"time"
)

// CreateWill makes your will; you can have one unreleased will at a time.
// heirs: address:percent pairs adding up to 100, at most 10, e.g.
// "g1abc...:70, g1def...:30"; the first heir gets any rounding remainder.
// silence: days without a sign of life before release, 1 to 3650, e.g. "180".
// successor: gets your admin rights in realms that check Holder, or empty.
// Needs your master key.
func CreateWill(cur realm, heirs, silence string, successor address) int {
	owner := enter(cur)
	mustUseMasterKey()
	if getActiveWill(owner) != nil {
		panic("you already have an unreleased will")
	}
	w := newWill(owner, parseHeirs(heirs, owner), parseSilence(silence))
	setSuccessor(w, parseSuccessor(successor, owner))
	emit("WillCreated", w)
	return w.ID
}

// SetHeirs replaces the heirs of your will id, in the CreateWill format.
func SetHeirs(cur realm, id int, heirs string) {
	w := touchOwnWill(enter(cur), id)
	indexHeirs(w, parseHeirs(heirs, w.Owner))
	emit("HeirsChanged", w)
}

// SetSuccessor sets the successor of your will id, the address that inherits
// your admin rights in realms that check Holder when the will is released. Use
// any address but yours, or leave it empty for nobody. Refused once a released
// will of yours has handed your admin rights over.
func SetSuccessor(cur realm, id int, successor address) {
	w := touchOwnWill(enter(cur), id)
	setSuccessor(w, parseSuccessor(successor, w.Owner))
	emit("SuccessorChanged", w, "successor", w.Successor.String())
}

// SetSilence changes the silence period of your will id, in the CreateWill
// format.
func SetSilence(cur realm, id int, silence string) {
	w := touchOwnWill(enter(cur), id)
	w.Silence = parseSilence(silence)
	emit("SilenceChanged", w)
}

// Ping is a sign of life for your will id: it restarts the silence period.
// Needs your master key.
func Ping(cur realm, id int) {
	touchOwnWill(enter(cur), id)
}

// Touch is a sign of life for the account that signed the transaction. Any
// realm can call it. Transactions signed with a session key do not count.
func Touch(cur realm) {
	enter(cur)
	markAlive(unsafe.OriginCaller())
}

// Deposit adds the GNOT sent with this call to your will id. Send it directly
// from a wallet or gnokey maketx call, not through another realm.
func Deposit(cur realm, id int) {
	caller, amount := enterWithGNOT(cur)
	w := touchOwnWill(caller, id)
	credit(w, gnot, amount)
	emit("Deposited", w, amountAttrs(gnot, amount)...)
}

// DepositToken moves amount of a GRC20 token, in its smallest unit, into your
// will id. token is its grc20reg key, e.g. "gno.land/r/gnoland/wugnot.wugnot".
// First approve this realm's address as a spender in the token's realm. A will
// holds at most 10 different assets, GNOT included.
func DepositToken(cur realm, id int, token string, amount int64) {
	w := touchOwnWill(enter(cur), id)
	mustBePositive(amount)
	pullToken(cur, w, token, amount)
	emit("Deposited", w, amountAttrs(token, amount)...)
}

// Withdraw sends amount of an asset from your will id back to you. asset is
// "ugnot" or a token key; amount is in its smallest unit (1 GNOT = 1000000
// ugnot).
func Withdraw(cur realm, id int, asset string, amount int64) {
	w := touchOwnWill(enter(cur), id)
	mustBePositive(amount)
	payOut(cur, w, asset, w.Owner, amount)
	emit("Withdrawn", w, amountAttrs(asset, amount)...)
}

// Revoke returns everything in your will id to you and deletes the will.
func Revoke(cur realm, id int) {
	w := touchOwnWill(enter(cur), id)
	for _, asset := range w.assets() {
		payOut(cur, w, asset, w.Owner, w.balance(asset))
	}
	removeWill(w)
	emit("WillRevoked", w)
}

// Release makes will id claimable once its owner has been silent for the
// whole silence period. Anyone but the owner can call it. Releasing also hands
// the owner's admin rights to the successor for good, unless an earlier
// released will has done so or the successor's admin rights already pass to
// the owner.
func Release(cur realm, id int) {
	w := enterAsOutsider(cur, id)
	if w.isReleased() {
		panic("the will is already released")
	}
	mustRelease(w)
}

// Claim sends heir's share of one asset ("ugnot" or a token key) from will id
// to heir, releasing the will first if it is due. Anyone can call it, except
// the owner before the will is released. Claim each asset separately.
func Claim(cur realm, id int, heir address, asset string) {
	w := enterAsOutsider(cur, id)
	h := w.heir(normalize(heir.String()))
	if h == nil {
		panic(heir.String() + " is not an heir of this will")
	}
	if !w.isReleased() {
		mustRelease(w)
	}
	if !w.snapshot.Has(asset) {
		panic("the will held no " + asset + " when it was released")
	}
	if h.hasClaimed(asset) {
		panic(h.Addr.String() + " has already been paid their share of " + asset)
	}

	share := w.shareOf(h, asset)
	if share == 0 {
		panic(h.Addr.String() + "'s share of " + asset + " rounds down to 0")
	}
	h.claimed.Set(asset, true)
	payOut(cur, w, asset, h.Addr, share)
	emit("Claimed", w, append([]string{"heir", h.Addr.String()}, amountAttrs(asset, share)...)...)
}

// Holder returns who holds the admin rights of addr: addr itself until a
// released will of addr hands them to a successor, then that successor's
// holder.
func Holder(addr address) address {
	return holderOf(normalize(addr.String()))
}

// ActiveWill returns the id of the unreleased will of owner, the one they can
// still change. Its status is "active" or "due".
func ActiveWill(owner address) (id int, ok bool) {
	if w := getActiveWill(normalize(owner.String())); w != nil {
		return w.ID, true
	}
	return 0, false
}

// WillInfo returns the owner and status ("active", "due" or "released") of
// will id. releaseAt is when it can be released, or when it was. ok is false
// if the will does not exist or was revoked.
func WillInfo(id int) (owner address, status string, releaseAt time.Time, ok bool) {
	w := getWill(id)
	if w == nil {
		return "", "", time.Time{}, false
	}
	releaseAt = w.releaseAt()
	if w.isReleased() {
		releaseAt = w.ReleasedAt
	}
	return w.Owner, string(w.status()), releaseAt, true
}

func mustRelease(w *Will) {
	if !w.isDue() {
		panic("the owner was last seen on " + formatTime(w.LastSeen) + "; the will can be released from " + formatTimeFrom(w.releaseAt()))
	}
	w.release()
	deactivate(w)
	recordRelease(w)
	if recordHandover(w) {
		emit("WillReleased", w, "successor", w.Successor.String())
		return
	}
	emit("WillReleased", w)
}

func mustBePositive(amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
}

func amountAttrs(asset string, amount int64) []string {
	return []string{"asset", asset, "amount", strconv.FormatInt(amount, 10)}
}

func emit(event string, w *Will, attrs ...string) {
	chain.Emit(event, append([]string{"id", strconv.Itoa(w.ID), "owner", w.Owner.String()}, attrs...)...)
}
