package nslogic

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/r/nym-mnsrehearsal001/nsdata/v3"
	"gno.land/r/nym-mnsrehearsal001/nsreserve/v3"
)

/*
FREE NAMES ARE RESERVATIONS NOW, and the holder mints.

The launch gives names away to X accounts and sells nothing. A claim needs
the X sign-in and nothing else. A free name is a record in our worker plus
a hashed reservation in the nsreserve realm that names nobody, written by
the granter in one daily batch for a fraction of a cent. Minting it into a
real record and a token is the holder's own transaction, paid by the
holder, let through by a voucher from the mint approver; the project pays
nothing for it.

THREE THINGS LIVE HERE.

 1. THE BLOCK. Every door that creates a name refuses a label somebody has
    reserved: paid registration, credits, the old per-name grant. The only
    way through a reservation is MintFree with a voucher for that name.

 2. THE MINT. MintFree runs every label rule again, at mint time, because
    the rules may have moved since the claim; gives the name the expiry the
    claim earned (the request time plus one term), not a fresh year; and
    leaves the token on the free hold: not transferable, not approvable,
    not listable, until UpgradeFreeName, which needs paid registration
    open. RenewFree extends it a year at a time, on a voucher too.

 3. THE PAID SWITCH. Paid registration is CLOSED on every domain until the
    admin opens it behind the timelock. Closing is instant, for the admin,
    the guardian and recovery. It does not touch the free mint.
*/

const (
	keyPaid   = "paid"      // global AND domain extra: "1" opens paid registration
	keyLegacy = "freegrant" // global: "1" reopens the per-name grant doors
)

// isWarden: the keys that may always move a switch the SAFE way.
func isWarden(a address) bool {
	return a != "" && (a == nsdata.GetAdmin() || a == nsdata.GetGuardian() || a == nsdata.GetRecovery())
}

func assertWarden(cur realm) {
	if !isWarden(cur.Previous().Address()) {
		panic("nslogic: restricted to the admin, the guardian or recovery")
	}
}

// -- the paid switch --

// PaidOpen reports whether names under a domain are for sale: only when
// the registry-wide switch AND the domain's own are both on. Both are off
// until somebody opens them, on every domain.
func PaidOpen(domainLabel string) bool {
	return nsdata.GetGlobal(keyPaid) == "1" && nsdata.GetDomainExtra(domainLabel, keyPaid) == "1"
}

func assertPaidOpen(domainLabel string) {
	if !PaidOpen(domainLabel) {
		panic("nslogic: paid registration is closed on *" + domainLabel)
	}
}

// SetPaidOpen moves the registry-wide paid switch. OPENING is the admin's,
// TIMELOCKED: it turns a giveaway into a shop. CLOSING is instant, for the
// admin, the guardian and recovery.
func SetPaidOpen(cur realm, on bool) {
	assertNoSend(cur)
	emitAdmin(cur, "SetPaidOpen", "on", fmtBool(on))
	if !on {
		assertWarden(cur)
		setGlobal(cur, keyPaid, "")
		return
	}
	assertIsAdmin(cur)
	requireAction(cur, actionID("SetPaidOpen", "true"))
	setGlobal(cur, keyPaid, "1")
}

// SetDomainPaid is the same switch for one domain, with the same rule.
func SetDomainPaid(cur realm, domainLabel string, on bool) {
	assertNoSend(cur)
	emitAdmin(cur, "SetDomainPaid", "label", domainLabel, "on", fmtBool(on))
	if !nsdata.DomainExists(domainLabel) {
		panic("nslogic: no such domain")
	}
	if !on {
		assertWarden(cur)
		setDomainExtra(cur, domainLabel, keyPaid, "")
		return
	}
	assertIsAdmin(cur)
	requireAction(cur, actionID("SetDomainPaid", domainLabel, "true"))
	setDomainExtra(cur, domainLabel, keyPaid, "1")
}

// -- the old per-name grant doors --

// LegacyGrantsOpen reports whether GrantFreeName, GrantFreeRenewal and
// RegisterFor answer at all. Off unless the admin reopened them.
func LegacyGrantsOpen() bool { return nsdata.GetGlobal(keyLegacy) == "1" }

func assertLegacyGrants() {
	if !LegacyGrantsOpen() {
		panic("nslogic: the per-name grant path is closed; free names are reservations (nsreserve) minted by their holders")
	}
}

// SetLegacyGrants reopens or closes the per-name grant doors. Opening is
// the admin's, timelocked; closing is instant for admin, guardian, recovery.
func SetLegacyGrants(cur realm, on bool) {
	assertNoSend(cur)
	emitAdmin(cur, "SetLegacyGrants", "on", fmtBool(on))
	if !on {
		assertWarden(cur)
		setGlobal(cur, keyLegacy, "")
		return
	}
	assertIsAdmin(cur)
	requireAction(cur, actionID("SetLegacyGrants", "true"))
	setGlobal(cur, keyLegacy, "1")
}

// -- the block --

// assertNotReserved is on every door that creates a name except the
// reservation's own.
func assertNotReserved(label, domainLabel string) {
	if nsreserve.Reserved(label, domainLabel) {
		panic("nslogic: " + label + "*" + domainLabel + " is reserved")
	}
}

// -- the mint --

/*
freeNameRefusal is every rule a label must pass to be given away, asked at
mint time: "" or the reason. The claim was checked by the issuer, possibly
months ago; this is the chain's own answer today.

NOT the claim cap (credits.gno): that is a price ceiling for credits, the
free launch sets it to zero, and tying the two together would refuse every
free name (verify N-6). The free tier's own line is: no premium name, and
no name priced above its domain's base.
*/
func freeNameRefusal(label, domainLabel string) (why string) {
	defer func() {
		if r := recover(); r != nil {
			if s, ok := r.(string); ok {
				why = strings.TrimPrefix(s, "nslogic: ")
			} else {
				why = "this label is not allowed"
			}
		}
	}()
	if st, _ := readRestoreState(nsdata.GetGlobal(keyRestore), time.Now().Unix()); st == "open" {
		return "the registry is being restored"
	}
	if nsdata.IsPaused() {
		return "the registry is paused"
	}
	if q := nsdata.QuarantineUntil(); time.Now().Unix() < q {
		return "recovery has quarantined giveaways until unix " + strconv.FormatInt(q, 10)
	}
	if !nsdata.DomainExists(domainLabel) || !DomainFree(domainLabel) {
		return "*" + domainLabel + " does not offer free names"
	}
	if !DomainOpen(domainLabel) {
		return "this domain is not accepting new names"
	}
	validateLabel(label)
	assertNotBlocked(label)
	if !FreeLabelAllowed(label) {
		return label + " is not available on the free tier"
	}
	if PremiumFor(label) != "" {
		return label + " is a premium name and is not given away"
	}
	if NamePriceUSD(domainLabel, label) > DomainBasePriceUSD(domainLabel) {
		return label + " is priced above an ordinary name and is not given away"
	}
	return ""
}

func nameTaken(label, domainLabel string) bool {
	if !nsdata.NameExists(label, domainLabel) {
		return false
	}
	_, _, expires, _, _, _ := nsdata.GetNameInfo(label, domainLabel)
	now := time.Now().Unix()
	return now < expires || now-expires < nsdata.GetGracePeriod()
}

// MintRefusal is why `holder` could not MintFree label*domain with this
// voucher right now, or "". For the site, before the wallet is asked.
func MintRefusal(holder address, label, domainLabel string, requestedAt, validUntil int64, sig string) string {
	if r := freeNameRefusal(label, domainLabel); r != "" {
		return r
	}
	if nameTaken(label, domainLabel) {
		return label + "*" + domainLabel + " is already registered"
	}
	return nsreserve.VoucherRefusal(nsreserve.KindMint, label, domainLabel, holder, requestedAt, validUntil, sig)
}

/*
MintFree is the one door a free name is minted through.

THE CALLER IS THE HOLDER, and pays: gas and the storage deposit come out of
the wallet that signs; the project pays nothing. What lets them through is
a voucher from the mint approver, issued by our worker only after a fresh X
sign-in by the account that claimed the name, saying: this wallet, this
name, requested at this second, valid until that one. nsreserve checks the
signature against the key the admin named, checks the wallet is
cur.Previous(), counts it against the approver's daily cap, and:

	if the name is RESERVED, requires the voucher to carry the
	reservation's own request time and spends the reservation;

	if it is NOT (the claimant is minting before the day's batch landed),
	requires a request time from the last three days.

Either way the name's expiry is the request time plus one term: minting is
never a fresh year. A voucher copied out of the mempool mints nothing for
anybody else, and nothing a second time: the name exists.
*/
func MintFree(cur realm, label, domainLabel string, requestedAt, validUntil int64, sig string) {
	assertNoSend(cur)
	if r := freeNameRefusal(label, domainLabel); r != "" {
		panic("nslogic: " + r)
	}
	caller := cur.Previous().Address()
	expires := nsreserve.ConsumeVoucher(cross(cur), nsreserve.KindMint, label, domainLabel, caller, requestedAt, validUntil, sig)
	now := time.Now().Unix()
	if expires <= now {
		panic("nslogic: this claim's year has already run out")
	}
	hadPrimary := nsdata.GetPrimary(caller) != ""
	// paid=false: the free hold is on the token from the instant it exists.
	if err := nsdata.RegisterNameRecord(cross(cur), label, domainLabel, caller, now, false); err != nil {
		panic(err)
	}
	// THE CLOCK STARTED AT THE CLAIM. The vault just wrote now + one term;
	// the name gets what the claim earned instead.
	nsdata.SetNameExpiryRecord(cross(cur), label, domainLabel, expires)
	// NO REVERSE POINTER WITHOUT BEING ASKED (audit M-5). The vault points
	// a wallet's first name back at it; for a name given away that is a
	// public wallet-to-persona link nobody chose. SetPrimaryName is the
	// holder's own call.
	if !hadPrimary {
		nsdata.ClearPrimaryRecord(cross(cur), caller)
	}
	chain.Emit("NameMinted", "tid", label+"*"+domainLabel, "owner", caller.String(),
		"expires", strconv.FormatInt(expires, 10))
}

// renewRefusal is everything RenewFree checks before the voucher.
func renewRefusal(holder address, label, domainLabel string) string {
	if st, _ := readRestoreState(nsdata.GetGlobal(keyRestore), time.Now().Unix()); st == "open" {
		return "the registry is being restored"
	}
	if nsdata.IsPaused() {
		return "the registry is paused"
	}
	if q := nsdata.QuarantineUntil(); time.Now().Unix() < q {
		return "recovery has quarantined giveaways until unix " + strconv.FormatInt(q, 10)
	}
	if !nsdata.NameExists(label, domainLabel) || nsdata.GetNameOwner(label, domainLabel) != holder {
		return "restricted to name owner"
	}
	if _, _, _, _, _, paid := nsdata.GetNameInfo(label, domainLabel); paid {
		return label + "*" + domainLabel + " is a paid name; it renews with RenewName"
	}
	return ""
}

// RenewRefusal is why `holder` could not RenewFree label*domain with this
// voucher right now, or "".
func RenewRefusal(holder address, label, domainLabel string, requestedAt, validUntil int64, sig string) string {
	if r := renewRefusal(holder, label, domainLabel); r != "" {
		return r
	}
	if _, _, was, _, _, _ := nsdata.GetNameInfo(label, domainLabel); requestedAt+nsdata.GetTermLength() <= was {
		return "not an extension: the name already runs to unix " + strconv.FormatInt(was, 10)
	}
	return nsreserve.VoucherRefusal(nsreserve.KindRenew, label, domainLabel, holder, requestedAt, validUntil, sig)
}

/*
RenewFree extends a minted free name on a RENEW voucher.

THE RENEWAL IS BOUND TO THE HOLDER (verify N-2). The old GrantFreeRenewal
asked for no proof, and anybody holding the granter key could push any free
name forward. Here the issuer checks X again and signs a voucher for the
wallet that holds the name; only that wallet can use it, it pays the gas,
and the name's expiry becomes the renewal request plus one term. A renew
voucher is its own kind: it cannot mint, and a mint voucher cannot renew.
*/
func RenewFree(cur realm, label, domainLabel string, requestedAt, validUntil int64, sig string) {
	assertNoSend(cur)
	caller := cur.Previous().Address()
	if r := renewRefusal(caller, label, domainLabel); r != "" {
		panic("nslogic: " + r)
	}
	_, _, was, _, _, _ := nsdata.GetNameInfo(label, domainLabel)
	expires := nsreserve.ConsumeVoucher(cross(cur), nsreserve.KindRenew, label, domainLabel, caller, requestedAt, validUntil, sig)
	if expires <= was {
		panic("nslogic: not an extension: the name already runs to unix " + strconv.FormatInt(was, 10))
	}
	nsdata.SetNameExpiryRecord(cross(cur), label, domainLabel, expires)
	chain.Emit("NameRenewedFree", "tid", label+"*"+domainLabel, "expires", strconv.FormatInt(expires, 10))
}

// -- the admin's levers on reservations --

const maxReserveBatch = 64

func assertHashBatch(hashes string) {
	if hashes == "" || len(hashes)%32 != 0 || len(hashes) > 32*maxReserveBatch {
		panic("nslogic: 1.." + fmtI(maxReserveBatch) + " hashes, 32 hex characters each, no separators")
	}
}

/*
ClearReservations deletes reservations: a wrong grant, a stolen granter's
squats, a name that has to be given up.

TIMELOCKED (audit H-1 asked for exactly this lever, and for the wait): it
takes a name away from whoever was promised it, so it is proposed in the
vault as `ClearReservations <hashes>`, waits, and recovery can veto it. Up
to 64 hashes behind one action.
*/
func ClearReservations(cur realm, hashes string) int {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "ClearReservations", "hashes", hashes)
	assertHashBatch(hashes)
	requireAction(cur, actionID("ClearReservations", hashes))
	return nsreserve.Clear(cross(cur), hashes)
}

/*
RevokeFreeNames ends MINTED free names: each one's expiry is set past the
grace period, so the label is reclaimable at once and the token is burned by
the next registration. Paid names are refused. TIMELOCKED, up to 64 token
ids (`a*meme,b*meme`) behind one action.

It reaches a name only while it is still on the free hold. That holds as
long as paid registration is closed, because UpgradeFreeName is behind the
paid switch: before opening paid, revoke what needs revoking (verify N-6).
*/
func RevokeFreeNames(cur realm, tids string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "RevokeFreeNames", "tids", tids)
	list := strings.Split(tids, ",")
	if tids == "" || len(list) > maxReserveBatch {
		panic("nslogic: 1.." + fmtI(maxReserveBatch) + " token ids, comma-separated")
	}
	type ref struct{ label, domain string }
	refs := make([]ref, 0, len(list))
	for _, tid := range list {
		label, domainLabel := splitTokenID(tid)
		if label == "" || domainLabel == "" || !IsFreeTier(label, domainLabel) {
			panic("nslogic: not a free-tier name: " + tid)
		}
		refs = append(refs, ref{label, domainLabel})
	}
	requireAction(cur, actionID("RevokeFreeNames", tids))
	gone := time.Now().Unix() - nsdata.GetGracePeriod() - 1
	for _, r := range refs {
		nsdata.SetNameExpiryRecord(cross(cur), r.label, r.domain, gone)
	}
}

// SetReserveDailyCap sets how many reservations and vouchers a day may
// carry. LOWERING is instant; RAISING is timelocked: the cap is what bounds
// a stolen granter or voucher key, and a stolen admin key must not lift it
// in the same breath.
func SetReserveDailyCap(cur realm, n int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetReserveDailyCap", "cap", fmtI(n))
	if n > nsreserve.DailyCap() {
		requireAction(cur, actionID("SetReserveDailyCap", fmtI(n)))
	}
	nsreserve.SetDailyCap(cross(cur), n)
}

// SetVoucherKey names the mint approver: the ed25519 public key that signs
// mint-now vouchers.
// TIMELOCKED: whoever holds the other half gives names away. Turning it
// off is nsreserve.ClearVoucherKey, instant, for admin, guardian, recovery.
func SetVoucherKey(cur realm, hexKey string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetVoucherKey", "key", hexKey)
	requireAction(cur, actionID("SetVoucherKey", hexKey))
	nsreserve.SetVoucherKey(cross(cur), hexKey)
}

// SetVoucherDailyCap sets how many names a day may be minted on vouchers:
// the mint approver's own cap, apart from the granter's. Lowering is
// instant, raising is timelocked.
func SetVoucherDailyCap(cur realm, n int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetVoucherDailyCap", "cap", fmtI(n))
	if n > nsreserve.VoucherCap() {
		requireAction(cur, actionID("SetVoucherDailyCap", fmtI(n)))
	}
	nsreserve.SetVoucherDailyCap(cross(cur), n)
}

// UnpauseReservations lifts nsreserve's pause. TIMELOCKED for the admin;
// recovery lifts it directly there.
func UnpauseReservations(cur realm) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "UnpauseReservations")
	requireAction(cur, actionID("UnpauseReservations"))
	nsreserve.UnpauseByLogic(cross(cur))
}
