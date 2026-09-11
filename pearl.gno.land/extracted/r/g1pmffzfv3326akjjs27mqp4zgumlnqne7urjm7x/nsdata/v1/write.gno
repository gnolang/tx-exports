package nsdata

import (
	"errors"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsnft/v1"
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
		// No token to burn and no reverse pointer to clear: domains are
		// records, not tokens, and `primary` only ever held name ids.
		domains.Remove(label)
	}
	domains.Set(label, &Domain{
		owner: owner, registered: now, expires: now + termLength,
		extra: avl.Tree{},
	})
	return nil
}

/*
ReassignDomainRecord moves a domain to a new owner and leaves its
configuration exactly where it was.

This is the durable fix nslogic.ReassignDomain's comment was waiting for.
The old path moved a domain through the name-transfer machinery, whose
wipe exists to clear a SELLER'S payment addresses — and so it silently
reopened closed domains, dropped their pricing to the default and released
their term caps, during the key-compromise recovery it exists for. A
domain's extras are its settings, not a previous holder's data, and there
is no previous holder: domains never reach a third party.

TTL resets, because it is the one field that is a caching promise made by
whoever held the record.
*/
func ReassignDomainRecord(cur realm, label string, to address) error {
	assertIsTrustedLogic(cur)
	if !to.IsValid() {
		return errStr("invalid owner address")
	}
	d, ok := getDomain(label)
	if !ok {
		return errStr("unknown domain")
	}
	d.owner = to
	d.ttl = 0
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
		_ = n
		owner := nsnft.OwnerOf(tid)
		clearPrimaryIfPointingAt(owner, tid)
		// Every name has a token, but a registry swapped in mid-migration
		// could meet a record whose token was already dealt with. Burning a
		// token that does not exist panics and would strand the domain
		// half-deleted, so ask first.
		if owner != "" {
			nsnft.Burn(cross(cur), tid)
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

	_ = d
	domains.Remove(label)
	return removed, true
}

// -- names --

/*
RegisterNameRecord creates `label*domain` and mints its token in nsnft.

`paid` false registers a FREE-TIER name: the token is minted with the free
hold already set, so there is never an instant in which it could be
approved and sold before a lock arrived. There is no longer any such thing
as a name without a token — see Name.

RECLAIM burns the previous holder's token first. The owner is read from
the ledger, never from the record, because the record has no owner.

AN ORPHAN TOKEN IS REFUSED. A token that exists with no record behind it
means a registry swap is mid-migration or something has gone wrong; either
way, registering over it would mint a second claim to a name somebody
already holds. RestoreNameRecord is the door for adopting one.
*/
func RegisterNameRecord(cur realm, label, domainLabel string, owner address, now int64, paid bool) error {
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
		// Evict the previous holder completely. The reverse pointer goes
		// first: leaving it would make the old owner resolve to a name the
		// reclaimer now owns.
		prev := nsnft.OwnerOf(tid)
		clearPrimaryIfPointingAt(prev, tid)
		if prev != "" {
			nsnft.Burn(cross(cur), tid)
		}
		names.Remove(treeKey)
	} else if nsnft.OwnerOf(tid) != "" {
		return errStr("a token for " + tid + " exists with no record behind it; restore it rather than registering over it")
	}

	nsnft.Mint(cross(cur), owner, tid, holdBits(paid, false))
	names.Set(treeKey, &Name{
		registered: now, expires: now + termLength,
		epoch: nsnft.Epoch(tid), extra: avl.Tree{},
	})
	setPrimaryIfNone(owner, tid)
	return nil
}

func holdBits(paid, frozen bool) int {
	b := 0
	if !paid {
		b |= 1 << lockBitFree
	}
	if frozen {
		b |= 1 << lockBitFrozen
	}
	return b
}

/*
setPrimaryIfNone gives an address a reverse pointer when it has none — or
when the one it has points at a name it no longer holds.

The second half is new. A pointer used to be cleared on every transfer,
because transfers went through this realm. They no longer do: a sale that
settles on nsnft leaves the seller's pointer aimed at a name they sold.
nslogic.ResolveAddress already refuses to answer with it, so it never
misleads anybody — but left in place it also blocked the seller's NEXT
registration from becoming their primary, which would have looked like a
bug in registration rather than a stale pointer.
*/
func setPrimaryIfNone(owner address, tid string) {
	k := owner.String()
	if v := primary.Get(k); v == nil || !ownsNow(owner, v.(string)) {
		primary.Set(k, tid)
	}
}

/*
UpgradeFreeRecord lifts the free-tier hold — the paid upgrade.

Preserves the dates: this is not a re-registration.

`newOwner` exists because the common case is somebody who decided to sell
and, in the same moment, wants the name in a wallet they control rather
than the key they were given. That move is a burn and a mint here, because
a held token cannot be transferred by design.

THE PROFILE DOES NOT GO WITH IT, and it used to. The move re-stamped the
old data to the new epoch and gave the recipient a reverse pointer — and
`newOwner` can be ANY address. An audit spelled out the attack: fill a
free name's profile with your own pay addresses, pay list price to upgrade
it into a victim's wallet, and the victim's name now asks people to pay
you, their address reverse-resolves to it, and their own later edits do
not clear it because the epoch is already current. So the data is left in
the previous epoch, where every read hides it and the next write destroys
it, and the recipient gets no pointer they never chose. A person moving
their own name to a new wallet re-enters their profile once; that is the
price of the move not being usable against somebody else.

Refused for a frozen name. Upgrading must never be the way a disputed name
gets out of its hold.
*/
func UpgradeFreeRecord(cur realm, label, domainLabel string, newOwner address) error {
	assertIsTrustedLogic(cur)
	if !newOwner.IsValid() {
		return errStr("invalid owner address")
	}
	n, ok := getName(label, domainLabel)
	if !ok {
		return errStr("unknown name")
	}
	if n.frozen {
		return errStr("name is frozen")
	}
	tid := nameTokenID(label, domainLabel)
	owner := nsnft.OwnerOf(tid)
	if owner == "" {
		return errStr("name has no token")
	}
	bits := nsnft.LockBits(tid)
	if bits&(1<<lockBitFree) == 0 {
		return errStr("name is already paid for")
	}
	if newOwner == owner {
		nsnft.SetLock(cross(cur), tid, lockBitFree, false)
		return nil
	}
	nsnft.Burn(cross(cur), tid)
	nsnft.Mint(cross(cur), newOwner, tid, bits&^(1<<lockBitFree))
	clearPrimaryIfPointingAt(owner, tid)
	// n.epoch is deliberately NOT moved, and no pointer is given — see above.
	return nil
}

/*
RestoreNameRecord is the migration door: records move, tokens do not.

A registry swapped in behind the same nsnft finds tokens that already
exist. This writes the record for one and ADOPTS its token, or mints one
when the ledger has none. It never moves a token: a snapshot must never
take a name from its current holder.

WHEN THE LEDGER DISAGREES WITH THE SNAPSHOT, IT WINS. This used to refuse,
and an audit showed where refusing leads: a name sold between the snapshot
and the restore panics the batch, gets dropped to finish the rest, and the
window seals — leaving the buyer's token with no record behind it, unable
to be renewed, resolved or registered, forever. So the record is written
for whoever holds the token now, and the snapshot's profile data is NOT
replayable onto it (restoredFor stays empty), because it was the seller's.

Gated like every write, and nslogic only reaches it through the restore
window, which is one-shot.
*/
func RestoreNameRecord(cur realm, label, domainLabel string, owner address, registered int64, paid bool) error {
	assertIsTrustedLogic(cur)
	if !owner.IsValid() {
		return errStr("invalid owner address")
	}
	if err := assertLabelKeySafe(label); err != nil {
		return err
	}
	if _, ok := getDomain(domainLabel); !ok {
		return errStr("unknown domain")
	}
	if _, ok := getName(label, domainLabel); ok {
		return errStr("name already has a record")
	}
	tid := nameTokenID(label, domainLabel)
	held := nsnft.OwnerOf(tid)
	if held == "" {
		nsnft.Mint(cross(cur), owner, tid, holdBits(paid, false))
		held = owner
	} else {
		/* NEVER ADOPT WHILE ANOTHER REGISTRY CAN STILL MINT.

		   The ledger's trust set is a set so an old and a new registry can
		   both be live during a migration — and an audit showed what that
		   allows: a name adopted here and renewed here still has its OLD
		   record, with its old expiry, in the old registry. Once that
		   lapses past grace, anyone registers the name through the old
		   logic realm, which burns the token and mints it to them. The
		   holder's paid, renewed name is gone. So adoption requires that
		   this registry is the only one the ledger trusts: pause and
		   untrust the old registry first, then restore. */
		if nsnft.Trusted() != cur.Address().String() {
			return errStr("adopting " + tid + " while the ledger trusts another registry would let that registry reclaim it; untrust the old registry first")
		}
		// Adopt. BOTH holds are set from what is being restored: the free
		// hold from the snapshot, and the frozen hold cleared, so a freeze
		// left by the old registry cannot linger on a record that reads
		// unfrozen. nslogic re-freezes after this if the snapshot says so.
		nsnft.SetLock(cross(cur), tid, lockBitFree, !paid)
		nsnft.SetLock(cross(cur), tid, lockBitFrozen, false)
	}
	rec := &Name{
		registered: registered, expires: registered + termLength,
		epoch: nsnft.Epoch(tid), extra: avl.Tree{},
	}
	if held == owner {
		rec.restoredFor = owner
		setPrimaryIfNone(owner, tid)
	}
	names.Set(nameTreeKey(label, domainLabel), rec)
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
	/* THE CHECK THE FIRST ATTEMPT GOT WRONG. It compared the caller to the
	   record's own owner copy, which stopped updating the moment ownership
	   moved to the token — so a buyer could not renew what they bought,
	   watched it lapse, and lost it to whoever re-registered. There is no
	   copy now. The ledger answers. */
	if caller != nsnft.OwnerOf(nameTokenID(label, domainLabel)) {
		return errStr("restricted to name owner")
	}
	n.expires = advanceTerm(n.expires, now)
	return nil
}

/*
SetNameFrozen sets the record's frozen bit AND the matching hold on the
token, in the same call.

The record bit alone used to be the whole mechanism, and it bound nothing
outside our own transfer wrappers — a disputed name could be moved on any
marketplace that called the token directly. The hold in nsnft binds every
path there is.
*/
func SetNameFrozen(cur realm, label, domainLabel string, frozen bool) {
	assertIsTrustedLogic(cur)
	mustGetName(label, domainLabel).frozen = frozen
	nsnft.SetLock(cross(cur), nameTokenID(label, domainLabel), lockBitFrozen, frozen)
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
	freshen(n, nameTokenID(label, domainLabel))
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
	freshen(n, nameTokenID(label, domainLabel))
	return setExtra(&n.extra, key, value)
}

/*
freshen is the WRITE half of the lazy wipe, and it is the half the first
attempt described in prose and never wrote.

If a name's data belongs to a previous ownership epoch, every extra and the
TTL are destroyed, and the record is re-stamped to the current epoch —
BEFORE the new value is written. So the buyer's first edit cannot carry
the seller's Bitcoin address forward as the buyer's: by the time the edit
lands, the address is gone.

It wipes everything rather than a list of sensitive keys, for the same
reason the old transfer wipe did: which keys matter is policy, and a list
kept here would be wrong the first time nslogic invents a key.

The read half — hiding stale data from everybody the instant the epoch
moves — is isFresh, used by every name read.
*/
func freshen(n *Name, tid string) { freshenTo(n, nsnft.Epoch(tid)) }

// freshenTo is freshen with the ledger's answer passed in, so the rule
// itself can be tested without a registry the ledger trusts.
func freshenTo(n *Name, epoch int64) {
	if n.epoch != epoch {
		n.extra = avl.Tree{}
		n.ttl = 0
		n.epoch = epoch
	}
}

func SetPrimaryRecord(cur realm, owner address, label, domainLabel string) error {
	assertIsTrustedLogic(cur)
	if _, ok := getName(label, domainLabel); !ok {
		return errStr("unknown name")
	}
	tid := nameTokenID(label, domainLabel)
	// nslogic checks this too. Checked here as well because a pointer at a
	// name somebody does not hold is the one thing reverse resolution must
	// never be able to say, and the ledger is one read away.
	if !ownsNow(owner, tid) {
		return errStr("restricted to the name's current owner")
	}
	primary.Set(owner.String(), tid)
	return nil
}

func ClearPrimaryRecord(cur realm, owner address) {
	assertIsTrustedLogic(cur)
	primary.Remove(owner.String())
}

// -- there are no raw NFT operations here any more --
//
// RawTransferNFT, RawApprove, RawSetApprovalForAll and TransferRecordOwner
// are gone. Transfers and approvals happen on nsnft, called directly by the
// holder or by a marketplace they approved — exactly how an external
// marketplace does it, so ours has no privileged path. A registry that
// could move tokens would be a registry that could steal them.

// -- config: all settable, none constant --

func SetTreasuryRecord(cur realm, addr address)     { assertIsTrustedLogic(cur); treasury = addr }
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
func SetLabelPatternRecord(cur realm, pattern string) {
	assertIsTrustedLogic(cur)
	labelPattern = pattern
}
func SetTokenURIBaseRecord(cur realm, base string) { assertIsTrustedLogic(cur); tokenURIBase = base }

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

// assertLabelKeySafe is a STRUCTURAL check, not a policy one. Character
// policy lives in the logic realm's tunable labelPattern; this is the
// narrow set of characters that would break the vault's own machinery no
// matter what policy is in force:
//
//	"*"  is the separator in both key encodings, so a label containing
//	     one makes storage keys and token ids ambiguous;
//	","  and newlines would corrupt the CSV snapshot exports, which are
//	     the disaster-recovery guarantee — assertExtraKey already refuses
//	     them for extension keys, and labels become keys just as much;
//	""   cannot address a record at all.
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
