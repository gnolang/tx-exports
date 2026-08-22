package nsdata

import (
	"errors"
	"strings"
	"time"

	"gno.land/p/g17l06jwgez8aun250609y6ej4048e6d78zfle3s/grc721"
	"gno.land/p/nt/avl/v0"
)

// Every function here is gated to trustedLogic and does exactly what it
// is told. Authorization beyond "is this the current logic realm" is
// deliberately NOT duplicated here: the vault stores, the logic realm
// decides. Re-checking policy in an unfixable realm sounds safer but
// bakes today's rules in permanently — a future feature that legitimately
// needs an admin to touch someone's record would be unbuildable.

// -- domains --

func RegisterDomainRecord(cur realm, label string, owner address, now time.Time) error {
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
		label: label, owner: owner, registered: now, expires: now.Add(termLength),
		extra: avl.Tree{},
	})
	mustMint(owner, domainTokenID(label))
	return nil
}

func RenewDomainRecord(cur realm, label string, caller address, now time.Time) error {
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
	d.expires, d.streak = advanceTerm(d.expires, d.streak, now)
	return nil
}

// advanceTerm extends a term by exactly one term-length from its
// PREVIOUS due date (never from `now` — the grace period must not
// extend the term) and returns the new streak.
//
// The streak guard is the part worth reading twice. Streak used to be
// incremented once per CALL, with no rate limit — so a "10 year diamond
// hands streak", rendered as a longevity signal, was buyable in a single
// block by calling renew ten times. It now only increments when the
// caller has actually lived into the final term of what they are
// renewing, making it a measure of elapsed time rather than of
// transactions sent.
//
// Deliberate tradeoff: renewing far in advance still extends the term
// but does not grow the streak, because no time has been survived yet.
// Renewing during grace resets the streak to 1 — the name was not lost,
// but the run of on-time renewals was broken.
func advanceTerm(expires time.Time, streak int64, now time.Time) (time.Time, int64) {
	onTime := isValidNow(expires, now)
	livedTheTerm := !now.Before(expires.Add(-termLength))
	next := expires.Add(termLength)
	// Anchoring to the previous due date is only safe while a renewal
	// cannot happen more than one term after it — i.e. while
	// gracePeriod <= termLength. That invariant held silently under the
	// old hardcoded constants and stopped holding the moment both became
	// settable: with a grace period longer than the term, a renewal paid
	// late in grace would return an expiry ALREADY IN THE PAST, leaving
	// the payer with a name that is still expired. Clamp forward so a
	// paid renewal always buys a live term, while keeping the anchor
	// behaviour in every normal case.
	if !next.After(now) {
		next = now.Add(termLength)
	}
	switch {
	case !onTime:
		return next, 1
	case livedTheTerm:
		return next, streak + 1
	default:
		return next, streak
	}
}

func SetDomainFrozen(cur realm, label string, frozen bool) {
	assertIsTrustedLogic(cur)
	mustGetDomain(label).frozen = frozen
}

func SetDomainExpiryRecord(cur realm, label string, expires time.Time) {
	assertIsTrustedLogic(cur)
	mustGetDomain(label).expires = expires
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

// -- names --

// RegisterNameRecord mints `label*domain`. mintNFT=false registers the
// record WITHOUT a GRC-721 token — the free tier (SPEC.md §19), where
// the per-mint token storage cost is not worth paying for a giveaway.
// Such a record is upgradeable later via PromoteToNFTRecord.
func RegisterNameRecord(cur realm, label, domainLabel string, owner address, now time.Time, mintNFT bool) error {
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
		label: label, domain: domainLabel, owner: owner,
		registered: now, expires: now.Add(termLength),
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

func RenewNameRecord(cur realm, label, domainLabel string, caller address, now time.Time) error {
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
	n.expires, n.streak = advanceTerm(n.expires, n.streak, now)
	return nil
}

func SetNameFrozen(cur realm, label, domainLabel string, frozen bool) {
	assertIsTrustedLogic(cur)
	mustGetName(label, domainLabel).frozen = frozen
}

// SetNameExpiryRecord sets an expiry directly. Backs the admin
// free-extension lever (SPEC.md §19) and any future term mechanic;
// the logic realm decides who may call it.
func SetNameExpiryRecord(cur realm, label, domainLabel string, expires time.Time) {
	assertIsTrustedLogic(cur)
	mustGetName(label, domainLabel).expires = expires
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
		mustGetDomain(tid[1:]).owner = to
	} else {
		label, domainLabel := splitTokenID(tid)
		mustGetName(label, domainLabel).owner = to
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
	// No auto-assign for the recipient — see RawTransferNFT.
	return nil
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
func SetTermLengthRecord(cur realm, d time.Duration)  { assertIsTrustedLogic(cur); termLength = d }
func SetGracePeriodRecord(cur realm, d time.Duration) { assertIsTrustedLogic(cur); gracePeriod = d }
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
func SetGlobalRecord(cur realm, key, value string) error {
	assertIsTrustedLogic(cur)
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
