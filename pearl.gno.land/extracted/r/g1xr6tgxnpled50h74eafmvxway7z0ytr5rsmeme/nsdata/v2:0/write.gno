package nsdata

import (
	"errors"
	"strings"

	"gno.land/p/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/grc721"
	"gno.land/p/nt/avl/v0"
)

// Every function here is gated to trustedLogic and does exactly what it
// is told. Authorization beyond "is this the current logic realm" is
// deliberately NOT duplicated here: the vault stores, the logic realm
// decides. Re-checking policy in an unfixable realm sounds safer but
// bakes today's rules in permanently — a future feature that legitimately
// needs an admin to touch someone's record would be unbuildable.

// -- domains --

func RegisterDomainRecord(cur realm, label string, owner address, now int64) error {
	assertIsTrustedLogic(cur)
	if !owner.IsValid() {
		return errStr("invalid owner address")
	}
	if err := assertLabelKeySafe(label); err != nil {
		return err
	}
	if d, ok := getDomain(label); ok {
		if d.frozen {
			return errStr("domain is frozen")
		}
		if !isReclaimable(d.expires, now) {
			return errStr("domain already registered and not yet reclaimable")
		}
		clearPrimaryIfPointingAt(d.owner, domainTokenID(label))
		mustBurn(domainTokenID(label))
		domains.Remove(label)
	}
	domains.Set(label, &Domain{
		owner: owner, registered: now, expires: now + termLength,
		extra: avl.Tree{},
	})
	mustMint(owner, domainTokenID(label))
	return nil
}

func RenewDomainRecord(cur realm, label string, caller address, now int64) error {
	assertIsTrustedLogic(cur)
	d, ok := getDomain(label)
	if !ok {
		return errStr("unknown domain")
	}
	if isReclaimable(d.expires, now) {
		return errStr("domain expired beyond grace period")
	}
	if caller != d.owner {
		return errStr("restricted to domain owner")
	}
	d.expires = advanceTerm(d.expires, now)
	return nil
}

// advanceTerm extends a term by exactly one term-length from its
// PREVIOUS due date — never from `now`, because the grace period must
// not silently extend the term somebody paid for.
//
// It no longer returns a streak. The streak used to be maintained here,
// with a guard against renewing repeatedly in one block to inflate it;
// that whole class of problem disappeared when the streak became a
// function of the registration date instead of a stored counter. See
// streakOf in auth.gno.
func advanceTerm(expires, now int64) int64 {
	// Anchoring to the previous due date is only safe while a renewal
	// cannot happen more than one term after it — i.e. while
	// gracePeriod <= termLength. That invariant held silently under the
	// old hardcoded constants and stopped holding the moment both became
	// settable: with a grace period longer than the term, a renewal paid
	// late in grace would return an expiry ALREADY IN THE PAST, leaving
	// the payer with a name that is still expired. Clamp forward so a
	// paid renewal always buys a live term, while keeping the anchor
	// behaviour in every normal case.
	next := expires + termLength
	if next <= now {
		next = now + termLength
	}
	return next
}

func SetDomainFrozen(cur realm, label string, frozen bool) {
	assertIsTrustedLogic(cur)
	mustGetDomain(label).frozen = frozen
}

func SetDomainExpiryRecord(cur realm, label string, expires int64) {
	assertIsTrustedLogic(cur)
	mustGetDomain(label).expires = expires
}

// SetDomainTTLRecord sets how long a resolver may cache answers about
// this domain, in seconds, where 0 means never cache. See Domain.ttl.
func SetDomainTTLRecord(cur realm, label string, ttl int64) error {
	assertIsTrustedLogic(cur)
	if ttl < 0 {
		return errStr("ttl may not be negative")
	}
	d, ok := getDomain(label)
	if !ok {
		return errStr("unknown domain")
	}
	d.ttl = ttl
	return nil
}

// SetDomainExtraRecord writes one arbitrary key on a domain — pricing,
// or whatever a future logic realm needs. An empty value deletes the
// key, so storage can be reclaimed.
func SetDomainExtraRecord(cur realm, label, key, value string) error {
	assertIsTrustedLogic(cur)
	d, ok := getDomain(label)
	if !ok {
		return errStr("unknown domain")
	}
	return setExtra(&d.extra, key, value)
}

// DeleteDomainRecord destroys a domain and the names beneath it: it
// burns every token, drops every reverse-resolution pointer into them,
// removes the records, and finally removes the domain itself.
//
// WHY IT EXISTS. Retiring a domain after a brand complaint, recovering
// the storage deposit on a domain that never sold, and clearing out fad
// domains nobody renewed. A logic realm cannot provide any of this,
// because the vault owns the trees and exposed no delete path — the only
// Remove call for a domain lived inside RegisterDomainRecord as the
// evict-and-replace step of re-registration.
//
// IT DELIBERATELY WORKS ON A DOMAIN WITH LIVE NAMES UNDER IT. The case
// this exists for is a demand to remove a domain entirely, where waiting
// for names to lapse is not an option. Compensating the holders is
// handled off chain and is deliberately not a contract concern.
//
// WHERE THIS DEPARTS FROM THE SPEC, stated plainly because it is a real
// difference: MAINNET.md §3d asks for all of it "in one call". It is
// bounded instead, deleting at most maxDeletePerCall names per call and
// reporting whether it finished. An unbounded loop over a tree that may
// hold any number of names is a transaction that stops fitting in a
// block once a domain gets popular — which would mean the domains most
// likely to attract a complaint are exactly the ones that could never be
// deleted, in a realm that can never be fixed. The caller repeats until
// `done`; for any domain of realistic size that is one call, so the
// no-preconditions requirement is preserved. What is NOT preserved is
// atomicity: a multi-call deletion is visible half-done between calls.
// Pause() first if that matters.
//
// Calling it on a domain that does not exist is a no-op reporting done,
// so a repeat loop terminates cleanly rather than panicking on the call
// that follows the last one.
func DeleteDomainRecord(cur realm, label string) (removed int64, done bool) {
	assertIsTrustedLogic(cur)
	d, ok := getDomain(label)
	if !ok {
		return 0, true
	}

	// Collect first, mutate second. Removing entries from the tree while
	// iterating it is undefined, and this loop exists precisely to remove
	// entries.
	start, end := domainRange(label)
	var keys []string
	names.Iterate(start, end, func(key string, v any) bool {
		if len(keys) >= maxDeletePerCall {
			return true
		}
		keys = append(keys, key)
		return false
	})

	for _, key := range keys {
		v := names.Get(key)
		if v == nil {
			continue
		}
		n := v.(*Name)
		// The name label is whatever follows "domain*" in the storage
		// key — the record no longer stores its own label.
		nameLabel := key[len(label)+1:]
		tid := nameTokenID(nameLabel, label)
		clearPrimaryIfPointingAt(n.owner, tid)
		if n.isNFT {
			mustBurn(tid)
		}
		names.Remove(key)
		removed++
	}

	// Anything left means the cap was hit; the domain record has to stay
	// so the next call can still find its name span.
	more := false
	names.Iterate(start, end, func(key string, v any) bool {
		more = true
		return true
	})
	if more {
		return removed, false
	}

	dtid := domainTokenID(label)
	// `primary` only ever holds NAME token ids (see RawTransferNFT), so
	// this cannot currently match. It is called anyway: the cost is one
	// lookup, and the alternative is a dangling pointer in a realm with
	// no way to add the cleanup later.
	clearPrimaryIfPointingAt(d.owner, dtid)
	mustBurn(dtid)
	domains.Remove(label)
	return removed, true
}

// -- names --

// RegisterNameRecord mints `label*domain`. mintNFT=false registers the
// record WITHOUT a GRC-721 token — the free tier (SPEC.md §19), where
// the per-mint token storage cost is not worth paying for a giveaway.
// Such a record is upgradeable later via PromoteToNFTRecord.
func RegisterNameRecord(cur realm, label, domainLabel string, owner address, now int64, mintNFT bool) error {
	assertIsTrustedLogic(cur)
	if !owner.IsValid() {
		return errStr("invalid owner address")
	}
	if err := assertLabelKeySafe(label); err != nil {
		return err
	}
	d, ok := getDomain(domainLabel)
	if !ok {
		return errStr("unknown domain")
	}
	if d.frozen {
		return errStr("domain is frozen")
	}
	if isReclaimable(d.expires, now) {
		return errStr("domain has lapsed past its grace period")
	}
	treeKey := nameTreeKey(label, domainLabel)
	tid := nameTokenID(label, domainLabel)
	if n, ok := getName(label, domainLabel); ok {
		if n.frozen {
			return errStr("name is frozen")
		}
		if !isReclaimable(n.expires, now) {
			return errStr("name already registered and not yet reclaimable")
		}
		// Evict the previous holder completely. Clearing the reverse
		// pointer FIRST matters: leaving it would make the old owner
		// resolve to a name the reclaimer now owns.
		clearPrimaryIfPointingAt(n.owner, tid)
		if n.isNFT {
			mustBurn(tid)
		}
		names.Remove(treeKey)
	}
	names.Set(treeKey, &Name{
		owner: owner, registered: now, expires: now + termLength,
		isNFT: mintNFT, extra: avl.Tree{},
	})
	if mintNFT {
		mustMint(owner, tid)
	}
	if primary.Get(owner.String()) == nil {
		primary.Set(owner.String(), tid)
	}
	return nil
}

// PromoteToNFTRecord mints the GRC-721 token for a record registered
// without one — the paid free-tier upgrade. Preserves expiry and streak;
// this is not a re-registration.
func PromoteToNFTRecord(cur realm, label, domainLabel string, newOwner address) error {
	assertIsTrustedLogic(cur)
	if !newOwner.IsValid() {
		return errStr("invalid owner address")
	}
	n, ok := getName(label, domainLabel)
	if !ok {
		return errStr("unknown name")
	}
	if n.isNFT {
		return errStr("name already has a token")
	}
	// Covers both upgrade paths: a holder who already had a wallet
	// (newOwner == n.owner) and a custodially-held name moving to the
	// claimant's now-real wallet in the same step.
	if newOwner != n.owner {
		clearPrimaryIfPointingAt(n.owner, nameTokenID(label, domainLabel))
		n.owner = newOwner
	}
	tid := nameTokenID(label, domainLabel)
	mustMint(n.owner, tid)
	n.isNFT = true
	// Same "first name becomes primary" rule as every other path that
	// changes ownership; without it a promoted name could leave its new
	// owner with no reverse resolution at all.
	if primary.Get(n.owner.String()) == nil {
		primary.Set(n.owner.String(), tid)
	}
	return nil
}

func RenewNameRecord(cur realm, label, domainLabel string, caller address, now int64) error {
	assertIsTrustedLogic(cur)
	n, ok := getName(label, domainLabel)
	if !ok {
		return errStr("unknown name")
	}
	if isReclaimable(n.expires, now) {
		return errStr("name expired beyond grace period")
	}
	if caller != n.owner {
		return errStr("restricted to name owner")
	}
	n.expires = advanceTerm(n.expires, now)
	return nil
}

func SetNameFrozen(cur realm, label, domainLabel string, frozen bool) {
	assertIsTrustedLogic(cur)
	mustGetName(label, domainLabel).frozen = frozen
}

// SetNameExpiryRecord sets an expiry directly. Backs the admin
// free-extension lever (SPEC.md §19) and any future term mechanic;
// the logic realm decides who may call it.
func SetNameExpiryRecord(cur realm, label, domainLabel string, expires int64) {
	assertIsTrustedLogic(cur)
	mustGetName(label, domainLabel).expires = expires
}

// SetNameTTLRecord sets how long a resolver may cache answers about this
// name, in seconds, where 0 means never cache. See Domain.ttl for why
// this exists and why the owner rather than the registry sets it.
func SetNameTTLRecord(cur realm, label, domainLabel string, ttl int64) error {
	assertIsTrustedLogic(cur)
	if ttl < 0 {
		return errStr("ttl may not be negative")
	}
	n, ok := getName(label, domainLabel)
	if !ok {
		return errStr("unknown name")
	}
	n.ttl = ttl
	return nil
}

// SetNameExtraRecord writes one arbitrary key on a name. This is where
// profile fields, cross-chain addresses, management-key hashes and tier
// markers live. An empty value deletes the key.
func SetNameExtraRecord(cur realm, label, domainLabel, key, value string) error {
	assertIsTrustedLogic(cur)
	n, ok := getName(label, domainLabel)
	if !ok {
		return errStr("unknown name")
	}
	return setExtra(&n.extra, key, value)
}

func SetPrimaryRecord(cur realm, owner address, label, domainLabel string) error {
	assertIsTrustedLogic(cur)
	if _, ok := getName(label, domainLabel); !ok {
		return errStr("unknown name")
	}
	primary.Set(owner.String(), nameTokenID(label, domainLabel))
	return nil
}

func ClearPrimaryRecord(cur realm, owner address) {
	assertIsTrustedLogic(cur)
	primary.Remove(owner.String())
}

// -- raw NFT operations (policy checks are the logic realm's job) --

func RawTransferNFT(cur realm, caller, from, to address, tid string) error {
	assertIsTrustedLogic(cur)
	if !to.IsValid() {
		return errStr("invalid recipient address")
	}
	if err := nft.TransferFrom(caller, from, to, grc721.TokenID(tid)); err != nil {
		return err
	}
	if strings.HasPrefix(tid, "*") {
		d := mustGetDomain(tid[1:])
		d.owner = to
		/* NOT WIPED. wipeOnHandover's rationale is entirely about NAMES:
		   clear a seller's payment addresses so a buyer does not inherit
		   them. A domain's extra slot is not user data — it is the
		   domain's configuration: price, len, nm, open and maxterm.
		   Wiping it silently reopened a deliberately closed domain,
		   dropped its pricing to the global default and released its
		   term cap, during an admin recovery, with nothing emitted.
		   Domains are project-owned and never reach a third party, so
		   there is no previous holder's data here to protect. */
		d.ttl = 0
	} else {
		label, domainLabel := splitTokenID(tid)
		n := mustGetName(label, domainLabel)
		n.owner = to
		wipeOnHandover(&n.extra, &n.ttl)
	}
	// Ownership moved, so the sender's reverse pointer is now a lie — drop
	// it. The recipient is deliberately NOT given one: `to` is chosen by
	// the sender and never consents, so auto-assigning would let anyone
	// brand an arbitrary address's public reverse-resolution just by
	// gifting it a name. The recipient opts in via SetPrimaryRecord.
	// (It would also have written a DOMAIN token id into a tree that only
	// ever holds name ids.)
	clearPrimaryIfPointingAt(from, tid)
	return nil
}

// TransferRecordOwner moves a record that has no GRC-721 token (free
// tier), where RawTransferNFT cannot be used because the token layer has
// nothing to move.
func TransferRecordOwner(cur realm, label, domainLabel string, to address) error {
	assertIsTrustedLogic(cur)
	if !to.IsValid() {
		return errStr("invalid recipient address")
	}
	n, ok := getName(label, domainLabel)
	if !ok {
		return errStr("unknown name")
	}
	if n.isNFT {
		return errStr("name has a token; use RawTransferNFT")
	}
	tid := nameTokenID(label, domainLabel)
	clearPrimaryIfPointingAt(n.owner, tid)
	n.owner = to
	wipeOnHandover(&n.extra, &n.ttl)
	// No auto-assign for the recipient — see RawTransferNFT.
	return nil
}

// wipeOnHandover clears everything the PREVIOUS owner attached to a
// record, and is called on every path that moves ownership.
//
// Without it a sale handed over the name while leaving the seller's data
// attached to it — including any payment addresses in `extra`. Anyone
// resolving that name afterwards would pay the seller, the buyer would
// receive nothing, and neither party would necessarily notice for
// months. That was the DEFAULT outcome of every sale, not an edge case.
// The vault already did the right thing on the other path — reclaiming a
// lapsed name calls names.Remove() and destroys the record — so transfer
// was simply the inconsistent one.
//
// It wipes ALL of `extra`, not a chosen subset. Deciding which keys are
// sensitive is policy, and policy belongs in the swappable half; a list
// of "dangerous keys" baked into a realm that can never be redeployed
// would be wrong the first time a future logic realm invents a key.
//
// TTL resets to 0 — never cache — for the same reason. It is the
// previous owner's caching preference, the new owner never chose it, and
// a handover is precisely the moment a stale cached answer sends money
// to the wrong person.
func wipeOnHandover(extra *avl.Tree, ttl *int64) {
	*extra = avl.Tree{}
	*ttl = 0
}

func RawApprove(cur realm, caller, to address, tid string) error {
	assertIsTrustedLogic(cur)
	return nft.Approve(caller, to, grc721.TokenID(tid))
}

func RawSetApprovalForAll(cur realm, caller, operator address, approved bool) error {
	assertIsTrustedLogic(cur)
	return nft.SetApprovalForAll(caller, operator, approved)
}

// -- config: all settable, none constant --

func SetTreasuryRecord(cur realm, addr address)      { assertIsTrustedLogic(cur); treasury = addr }
func SetTermLengthRecord(cur realm, seconds int64)  { assertIsTrustedLogic(cur); termLength = seconds }
func SetGracePeriodRecord(cur realm, seconds int64) { assertIsTrustedLogic(cur); gracePeriod = seconds }

// SetMaxDeletePerCallRecord tunes how much work one DeleteDomainRecord
// call will do. See maxDeletePerCall in types.gno.
func SetMaxDeletePerCallRecord(cur realm, n int) {
	assertIsTrustedLogic(cur)
	if n < 1 {
		n = 1
	}
	maxDeletePerCall = n
}
func SetLabelPatternRecord(cur realm, pattern string) { assertIsTrustedLogic(cur); labelPattern = pattern }
func SetTokenURIBaseRecord(cur realm, base string)    { assertIsTrustedLogic(cur); tokenURIBase = base }

func SetLabelLengthRecord(cur realm, minLen, maxLen int) {
	assertIsTrustedLogic(cur)
	minLabelLen, maxLabelLen = minLen, maxLen
}

func SetExtraLimitsRecord(cur realm, keyLen, valueLen, entries int) {
	assertIsTrustedLogic(cur)
	maxExtraKeyLen, maxExtraValueLen, maxExtraEntries = keyLen, valueLen, entries
}

// SetGlobalRecord writes one arbitrary package-level key — fee rates,
// default prices, a custodian address, points balances, claim records.
// Anything global that does not exist yet goes here instead of needing a
// package variable that could never be added after deployment.
// Keys the restore machinery owns. Written only by RestoreGlobal's own
// path, never by a general setter — because nslogic's SetGlobal forwards
// whatever key an admin passes, and one call writing "restore" reopened
// a seal that restore.gno calls irreversible. Enforced HERE as well as
// there, so a future logic realm cannot drop the guard by forgetting it.
var reservedGlobals = []string{"restore", "restored"}

func SetGlobalRecord(cur realm, key, value string) error {
	assertIsTrustedLogic(cur)
	for _, r := range reservedGlobals {
		if key == r {
			return errStr("that key belongs to the restore machinery and is not settable here")
		}
	}
	return setExtra(&globals, key, value)
}

// SetReservedGlobalRecord is the restore machinery's own door to the
// keys above. Same trust gate; separate name, so a general-purpose
// setter can never reach them by accident.
func SetReservedGlobalRecord(cur realm, key, value string) error {
	assertIsTrustedLogic(cur)
	found := false
	for _, r := range reservedGlobals {
		if key == r {
			found = true
		}
	}
	if !found {
		return errStr("not a reserved key; use SetGlobalRecord")
	}
	return setExtra(&globals, key, value)
}

// setExtra applies the shared bounds and the delete-on-empty rule.
func setExtra(t *avl.Tree, key, value string) error {
	if err := assertExtraKey(key); err != nil {
		return err
	}
	if value == "" {
		t.Remove(key)
		return nil
	}
	if len(value) > maxExtraValueLen {
		return errStr("extra value too long")
	}
	if t.Get(key) == nil && t.Size() >= maxExtraEntries {
		return errStr("too many extra entries")
	}
	t.Set(key, value)
	return nil
}

// assertExtraKey keeps extension keys free of the characters that would
// make a snapshot ambiguous. Export lists keys as CSV, so a key
// containing a comma or a newline would silently corrupt a backup — and
// a backup you cannot trust is the one thing this realm cannot afford.
func assertExtraKey(key string) error {
	if key == "" || len(key) > maxExtraKeyLen {
		return errStr("bad extra key")
	}
	if strings.ContainsAny(key, ",\n\r") {
		return errStr("extra key may not contain commas or newlines")
	}
	return nil
}

// mustMint / mustBurn PANIC rather than returning an error, deliberately.
//
// In Gno a returned error does not revert anything — only a panic does.
// These calls happen AFTER the record has already been written, so a
// caller that merely logged the error would leave a record whose isNFT
// flag disagrees with the token ledger, permanently, in a realm that
// cannot be redeployed. A failure here is an internal invariant
// violation rather than a user-facing condition, so the correct response
// is to abort the whole transaction and leave no trace.
func mustMint(owner address, tid string) {
	if err := nft.Mint(owner, grc721.TokenID(tid)); err != nil {
		panic("nsdata: mint failed for " + tid + ": " + err.Error())
	}
}

func mustBurn(tid string) {
	if err := nft.Burn(grc721.TokenID(tid)); err != nil {
		panic("nsdata: burn failed for " + tid + ": " + err.Error())
	}
}

// assertLabelKeySafe is a STRUCTURAL check, not a policy one. Character
// policy lives in the logic realm's tunable labelPattern; this is the
// narrow set of characters that would break the vault's own machinery no
// matter what policy is in force:
//
//   "*"  is the separator in both key encodings, so a label containing
//        one makes storage keys and token ids ambiguous;
//   ","  and newlines would corrupt the CSV snapshot exports, which are
//        the disaster-recovery guarantee — assertExtraKey already refuses
//        them for extension keys, and labels become keys just as much;
//   ""   cannot address a record at all.
//
// Enforcing it here rather than trusting the logic realm matters because
// labelPattern is admin-tunable: loosening it must never be able to
// silently corrupt a backup in a realm that cannot be redeployed.
func assertLabelKeySafe(label string) error {
	if label == "" {
		return errStr("empty label")
	}
	if strings.ContainsAny(label, "*,\n\r") {
		return errStr("label may not contain '*', commas or newlines")
	}
	return nil
}

func errStr(s string) error { return errors.New(s) }
