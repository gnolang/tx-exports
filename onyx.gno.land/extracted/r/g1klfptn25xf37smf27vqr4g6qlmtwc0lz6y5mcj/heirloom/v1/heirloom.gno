package heirloom

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"time"
)

// CreateWill makes your will and returns its id; one unreleased will at a time.
// heirs: address:percent pairs adding up to 100, at most 10, e.g.
// "g1abc...:70, g1def...:30"; the first heir gets any rounding remainder.
// silence: days without a sign of life, 1 to 3650, e.g. "180".
// successor: gets your admin rights in realms that check Holder, or empty.
// Needs your master key.
func CreateWill(cur realm, heirs, silence string, successor address) int {
	owner := enter(cur)
	mustUseMasterKey()
	if getActiveWill(owner) != nil {
		panic("you already have an unreleased will")
	}
	list, period, next := parseHeirs(heirs, owner), parseSilence(silence), parseSuccessor(successor, owner)
	w := newWill(owner, list, period)
	setSuccessor(w, next)
	emit("WillCreated", w)
	return w.ID
}

// SetHeirs replaces the heirs of your will id, in the CreateWill format.
// Needs your master key.
func SetHeirs(cur realm, id int, heirs string) {
	w := touchOwnWill(enter(cur), id)
	indexHeirs(w, parseHeirs(heirs, w.Owner))
	emit("HeirsChanged", w)
}

// SetSuccessor sets the successor of your will id, or clears it if empty.
// Refused for an address that declined, and once a released will of yours has
// handed your admin rights over. Needs your master key.
func SetSuccessor(cur realm, id int, successor address) {
	w := touchOwnWill(enter(cur), id)
	setSuccessor(w, parseSuccessor(successor, w.Owner))
	emit("SuccessorChanged", w, "successor", w.Successor.String())
}

// SetSilence changes the silence period of your will id, in days, 1 to 3650.
// Needs your master key.
func SetSilence(cur realm, id int, silence string) {
	w := touchOwnWill(enter(cur), id)
	w.Silence = parseSilence(silence)
	emit("SilenceChanged", w)
}

// Ping restarts the silence period of your will id and cancels a release
// request. Needs your master key.
func Ping(cur realm, id int) {
	touchOwnWill(enter(cur), id)
}

// Touch is a sign of life for the account that signed the transaction, unless
// it was signed with a session key. Any realm can call it.
func Touch(cur realm) {
	enter(cur)
	markAlive(unsafe.OriginCaller())
}

// Deposit adds the GNOT sent with this call to your will id. Only a direct call
// from a wallet or gnokey maketx call is accepted. Needs your master key.
func Deposit(cur realm, id int) {
	caller, amount := enterWithGNOT(cur)
	w := touchOwnWill(caller, id)
	credit(w, gnot, amount)
	emit("Deposited", w, amountAttrs(gnot, amount)...)
}

// DepositToken moves amount of a GRC20 token, in its smallest unit, into your
// will id. token is its grc20reg key; approve this realm as a spender first. At
// most 10 different assets per will, GNOT included. Needs your master key.
func DepositToken(cur realm, id int, token string, amount int64) {
	w := touchOwnWill(enter(cur), id)
	mustBePositive(amount)
	pullToken(cur, w, token, amount)
	emit("Deposited", w, amountAttrs(token, amount)...)
}

// Withdraw sends amount of asset ("ugnot" or a token key), in its smallest
// unit, from your will id to you. Needs your master key.
func Withdraw(cur realm, id int, asset string, amount int64) {
	w := touchOwnWill(enter(cur), id)
	mustBePositive(amount)
	payOut(cur, w, asset, w.Owner, amount)
	emit("Withdrawn", w, amountAttrs(asset, amount)...)
}

// Revoke sends everything in your will id to you and deletes the will.
// Needs your master key.
func Revoke(cur realm, id int) {
	w := touchOwnWill(enter(cur), id)
	for _, asset := range w.assets() {
		payOut(cur, w, asset, w.Owner, w.balance(asset))
	}
	removeWill(w)
	emit("WillRevoked", w)
}

// Release asks to release will id once the silence period has passed, or
// releases it once 7 days have passed since that request with no sign of life.
// Returns "requested" or "released". Anyone but the owner can call it.
func Release(cur realm, id int) string {
	w, signer := enterAsOutsider(cur, id)
	if w.isReleased() {
		panic("the will is already released")
	}
	if w.isRequested() {
		mustRelease(w)
	} else {
		mustRequest(w, signer)
	}
	return string(w.status())
}

// Claim sends heir's share of one asset ("ugnot" or a token key) from will id
// to heir, releasing the will first if it can be released. Anyone can call it,
// except the owner before release.
func Claim(cur realm, id int, heir address, asset string) {
	w, _ := enterAsOutsider(cur, id)
	h := mustGetHeir(w, heir)
	if !w.isReleased() {
		mustRelease(w)
	}
	if !w.held.Has(asset) {
		panic("the will held no " + asset + " when it was released")
	}
	if h.hasClaimed(asset) {
		panic(h.Addr.String() + " has already been paid their share of " + asset)
	}
	share := w.shareOf(h, asset)
	if share == 0 {
		panic(h.Addr.String() + "'s share of " + asset + " rounds down to 0")
	}
	payHeir(cur, w, h, asset, share)
}

// ClaimAll sends heir every unpaid share from will id, like Claim for each
// asset. If one transfer fails, nothing is paid; Claim each asset instead.
func ClaimAll(cur realm, id int, heir address) {
	w, _ := enterAsOutsider(cur, id)
	h := mustGetHeir(w, heir)
	if !w.isReleased() {
		mustRelease(w)
	}
	paid := 0
	for _, asset := range w.assets() {
		if share := w.shareOf(h, asset); share > 0 && !h.hasClaimed(asset) {
			payHeir(cur, w, h, asset, share)
			paid++
		}
	}
	if paid == 0 {
		panic(h.Addr.String() + " has nothing left to claim")
	}
}

// Hide takes will id off your page at :u/<your address> if it names you as an
// heir or successor. You stay an heir or successor.
func Hide(cur realm, id int) {
	caller := enter(cur)
	w := mustGetWill(id)
	if !w.names(caller) {
		panic("will " + strconv.Itoa(id) + " does not name you as an heir or successor")
	}
	hideWill(w, caller)
	markAlive(unsafe.OriginCaller())
	emit("WillHidden", w, "by", caller.String())
}

// Unhide puts will id back on your page after Hide.
func Unhide(cur realm, id int) {
	caller := enter(cur)
	w := mustGetWill(id)
	if !w.hiddenFor(caller) {
		panic("will " + strconv.Itoa(id) + " is not hidden from your page")
	}
	unhideWill(w, caller)
	markAlive(unsafe.OriginCaller())
	emit("WillUnhidden", w, "by", caller.String())
}

// Decline removes you as the successor of will id before it is released. The
// owner cannot name you as successor again.
func Decline(cur realm, id int) {
	caller := enter(cur)
	w := mustGetWill(id)
	switch {
	case w.isReleased():
		panic("will " + strconv.Itoa(id) + " is already released; use ReturnRights")
	case w.Successor != caller:
		panic("you are not the successor of will " + strconv.Itoa(id))
	}
	setSuccessor(w, "")
	recordDecline(w.Owner, caller)
	markAlive(unsafe.OriginCaller())
	emit("SuccessionDeclined", w, "by", caller.String())
}

// ReturnRights gives owner back the admin rights that owner's released will
// handed to you. Only that direct successor can call it. Needs your master key.
func ReturnRights(cur realm, owner address) {
	caller := enter(cur)
	mustUseMasterKey()
	h := mustReturnRights(normalize(owner.String()), caller)
	markAlive(unsafe.OriginCaller())
	if w := getWill(h.WillID); w != nil {
		emit("RightsReturned", w, "by", caller.String())
	}
}

// HomeURL returns the gnoweb path of the Heirloom home page.
func HomeURL() string {
	return webPath
}

// WillURL returns the gnoweb path of the page of will id.
func WillURL(id int) string {
	return webPath + ":will/" + strconv.Itoa(id)
}

// UserURL returns the gnoweb path of the Heirloom page of addr.
func UserURL(addr address) string {
	return webPath + ":u/" + addr.String()
}

// Holder returns who holds the admin rights of addr: addr itself, or the end
// of the chain of handovers that starts at addr.
func Holder(addr address) address {
	return holderOf(normalize(addr.String()))
}

// ActiveWill returns the id of the unreleased will of owner, whose status is
// "active", "due" or "requested".
func ActiveWill(owner address) (id int, ok bool) {
	if w := getActiveWill(normalize(owner.String())); w != nil {
		return w.ID, true
	}
	return 0, false
}

// WillInfo returns the owner and status of will id: "active", "due" (a release
// can be requested), "requested" or "released". releaseAt is the next moment
// that status can change, or the release time. ok is false if there is no will.
func WillInfo(id int) (owner address, status string, releaseAt time.Time, ok bool) {
	w := getWill(id)
	if w == nil {
		return "", "", time.Time{}, false
	}
	switch {
	case w.isReleased():
		releaseAt = w.ReleasedAt
	case w.isRequested():
		releaseAt = w.objectionEnds()
	default:
		releaseAt = w.releaseAt()
	}
	return w.Owner, string(w.status()), releaseAt, true
}

func mustGetHeir(w *Will, heir address) *Heir {
	h := w.heir(normalize(heir.String()))
	if h == nil {
		panic(heir.String() + " is not an heir of this will")
	}
	return h
}

func payHeir(cur realm, w *Will, h *Heir, asset string, share int64) {
	h.claimed.Set(asset, true)
	payShare(cur, asset, h.Addr, share)
	emit("Claimed", w, append([]string{"heir", h.Addr.String()}, amountAttrs(asset, share)...)...)
}

func notDue(w *Will) string {
	return "the owner was last seen on " + formatTime(w.LastSeen) + "; anyone but the owner can ask to release the will from " + formatTimeFrom(w.releaseAt())
}

func mustRequest(w *Will, by address) {
	if !w.isDue() {
		panic(notDue(w))
	}
	w.RequestedAt, w.RequestedBy = time.Now(), by
	emit("ReleaseRequested", w, "by", by.String())
}

func mustRelease(w *Will) {
	switch {
	case !w.isRequested() && !w.isDue():
		panic(notDue(w))
	case !w.isRequested():
		panic("nobody has asked to release this will yet: call Release first")
	case time.Now().Before(w.objectionEnds()):
		panic("release was requested on " + formatTime(w.RequestedAt) + "; the owner can object until " + formatTimeFrom(w.objectionEnds()))
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
