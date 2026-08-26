package nslogic

import (
	"strconv"
	"strings"
	"time"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

/*
REBUILDING THE REGISTRY ON A NEW CHAIN.

WHY THIS EXISTS. gno.land replaces testnets rather than preserving them:
topaz-1 was superseded by sapphire-1 on twenty-four hours' notice and
every name registered on it went to zero. tools/snapshot.js keeps a
complete off-chain copy of the vault for exactly that morning. This is
the other half — the path that turns a snapshot back into a live
registry, so that people who paid for a name get that name back rather
than an apology.

THIS IS A BACKDOOR, AND IT IS TREATED AS ONE.

A function that can mint any name, to any address, with any registration
date, is precisely the thing that would make every name here worthless
if it could be reached whenever the admin felt like it. Ownership means
nothing if history is editable on demand. So the capability is not
merely admin-gated — admin-gated is what everything else here already
is, and it is not enough for this. It is a ONE-SHOT:

  - it starts closed, and on a chain where nothing needs restoring it is
    sealed immediately and can never be used at all;
  - opening it is a deliberate, separate, announced act with a deadline
    attached, so forgetting to close it is not the same as leaving it
    open forever;
  - sealing is IRREVERSIBLE. Sealed cannot be reopened. There is no
    argument that unseals it, including a good one;
  - it refuses to touch a name that already exists. It fills gaps in an
    empty registry; it cannot rewrite a live one.

WHERE THE SEAL LIVES, AND WHY IT IS NOT HERE. This realm holds no state
at all — that is the whole reason prices and names survive a logic
upgrade untouched. If the seal lived in this realm's variables it would
reset to "never opened" the moment a new generation was deployed, which
would make "irreversible" a lie with a two-hour shelf life. It lives in
the vault's global slot instead, so a new logic generation inherits a
seal it cannot talk its way out of.

WHAT THAT DOES AND DOES NOT GUARANTEE. It is a real barrier against
every accident and against this realm being reached later for something
it was not built for. It is not a barrier against the admin themselves,
who can deploy a further logic realm and have the vault trust it — but
that is already total control by definition, and no flag in a realm the
admin can replace was ever going to change it. What the seal gives is
the thing that actually matters in practice: the state is public, it is
checkable by anybody at any time through RestoreStatus, and moving it
backwards leaves a permanent trace on chain.

WHAT IT DELIBERATELY DOES NOT RESTORE. Marketplace listings and open
votes. Those live in their own realms, are intentions rather than facts,
and are re-creatable by the people who made them in one transaction
each. Re-materialising somebody's month-old asking price as though they
had just set it would be inventing a decision on their behalf.
*/

// The vault key holding the state of this whole mechanism.
const keyRestore = "restore"

// Restore states, stored as a string in the vault's global slot.
const (
	restoreNever  = ""       // never opened; the normal state forever
	restoreSealed = "sealed" // closed permanently; cannot be reopened
	restoreOpen   = "open:"  // followed by the unix second it lapses
)

// The longest a restore window may be left open. A restore is a day of
// work, not a season, and an unbounded window is just "open forever"
// spelled differently — the failure here is nobody remembering to seal
// it, so the deadline seals it for them.
const maxRestoreDays = 30

// RestoreStatus reports the state of the restore mechanism in a form a
// person can read, and is deliberately PUBLIC AND UNAUTHENTICATED.
// Anybody at all can check whether this registry currently has a door in
// it, without asking us and without trusting the answer we would give.
//
// Returns the state ("never", "open", "expired" or "sealed"), the unix
// second an open window lapses (0 otherwise), and how many records have
// been restored in the lifetime of this vault.
func RestoreStatus() (state string, deadline int64, restored int64) {
	st, d := readRestoreState(nsdata.GetGlobal(keyRestore), time.Now().Unix())
	return st, d, restoredCount()
}

// readRestoreState is the state machine on its own, with the clock passed
// in. Split out so the one piece of logic that decides whether the door
// is open can be tested exhaustively without a chain under it.
func readRestoreState(raw string, now int64) (state string, deadline int64) {
	switch {
	case raw == restoreSealed:
		return "sealed", 0
	case strings.HasPrefix(raw, restoreOpen):
		d, err := strconv.ParseInt(raw[len(restoreOpen):], 10, 64)
		if err != nil || d <= 0 {
			// An unparseable deadline is read as NO permission. The safe
			// reading of a door whose lock is broken is "shut" — a corrupt
			// value must never widen what somebody is allowed to do.
			return "sealed", 0
		}
		if now >= d {
			return "expired", d
		}
		return "open", d
	}
	return "never", 0
}

const keyRestoredCount = "restored"

func restoredCount() int64 {
	if v := nsdata.GetGlobal(keyRestoredCount); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return 0
}

func bumpRestored(cur realm, n int64) {
	nsdata.SetGlobalRecord(cross(cur), keyRestoredCount,
		strconv.FormatInt(restoredCount()+n, 10))
}

// assertRestoring is the gate every Restore* function passes through.
func assertRestoring(cur realm) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	state, _, _ := RestoreStatus()
	switch state {
	case "open":
		return
	case "sealed":
		panic("nslogic: restore was sealed and cannot be reopened. This is " +
			"not recoverable by design — a registry whose history can be " +
			"rewritten on request does not have owners, it has guests.")
	case "expired":
		panic("nslogic: the restore window has lapsed. Deploy a fresh vault " +
			"and open a new window there; an expired one does not reopen.")
	}
	panic("nslogic: restore has never been opened. Call OpenRestore first, " +
		"and mean it.")
}

// OpenRestore opens the window, once, for a bounded number of days.
//
// Only ever valid on a chain where the registry is EMPTY because the
// previous chain was retired. It cannot be called on a vault that has
// been sealed, and it cannot be called twice.
func OpenRestore(cur realm, days int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)

	state, _, _ := RestoreStatus()
	if state != "never" {
		panic("nslogic: restore may be opened exactly once per vault; this " +
			"one is already " + state + ". A door that reopens is a door.")
	}
	if days < 1 || days > maxRestoreDays {
		panic("nslogic: a restore window must be between 1 and " +
			strconv.Itoa(maxRestoreDays) + " days")
	}
	deadline := time.Now().Unix() + days*86400
	nsdata.SetGlobalRecord(cross(cur), keyRestore,
		restoreOpen+strconv.FormatInt(deadline, 10))
}

// SealRestore closes the door permanently. Valid from any state,
// including "never" — which is how it should be called on a chain that
// has nothing to restore, so that the capability is provably dead rather
// than merely unused.
//
// There is no matching unseal, and adding one later would defeat every
// word written at the top of this file.
func SealRestore(cur realm) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	nsdata.SetGlobalRecord(cross(cur), keyRestore, restoreSealed)
}

/*
RestoreDomain re-creates one domain with its original dates.

ORDER MATTERS: domains before their names. The vault refuses to register
a name under a domain that does not exist or had lapsed at the moment
the name claims to have been registered, which is correct behaviour and
also exactly the order a snapshot should be replayed in.

The vault's own registration path sets `registered` to whatever instant
it is handed and derives the expiry from the term length, so the
registration date is restored by passing the ORIGINAL one, and the
expiry is then corrected to the recorded value rather than a computed
one. Anything else would quietly hand everybody a fresh term.
*/
func RestoreDomain(cur realm, label string, owner address, registered, expires, ttl int64, frozen bool) {
	assertRestoring(cur)
	if nsdata.DomainExists(label) {
		panic("nslogic: " + label + " already exists; restore fills an empty " +
			"registry and never overwrites a live record")
	}
	if registered <= 0 || expires <= 0 {
		panic("nslogic: a restored record needs its original dates")
	}
	if err := nsdata.RegisterDomainRecord(cross(cur), label, owner, registered); err != nil {
		panic("nslogic: " + err.Error())
	}
	nsdata.SetDomainExpiryRecord(cross(cur), label, expires)
	if ttl != 0 {
		if err := nsdata.SetDomainTTLRecord(cross(cur), label, ttl); err != nil {
			panic("nslogic: " + err.Error())
		}
	}
	if frozen {
		nsdata.SetDomainFrozen(cross(cur), label, true)
	}
	bumpRestored(cur, 1)
}

// RestoreName re-creates one name. See RestoreDomain on ordering and on
// why the dates are passed rather than computed.
//
// isNFT is carried across rather than assumed: the free tier registers
// names without a token, and minting one for somebody who never had it
// would silently upgrade their record and desynchronise the two
// ownership ledgers.
func RestoreName(cur realm, label, domainLabel string, owner address, registered, expires, ttl int64, frozen, isNFT bool) {
	assertRestoring(cur)
	if nsdata.NameExists(label, domainLabel) {
		panic("nslogic: " + label + "*" + domainLabel + " already exists; " +
			"restore fills an empty registry and never overwrites a live record")
	}
	if registered <= 0 || expires <= 0 {
		panic("nslogic: a restored record needs its original dates")
	}
	if err := nsdata.RegisterNameRecord(cross(cur), label, domainLabel, owner, registered, isNFT); err != nil {
		panic("nslogic: " + err.Error())
	}
	nsdata.SetNameExpiryRecord(cross(cur), label, domainLabel, expires)
	if ttl != 0 {
		if err := nsdata.SetNameTTLRecord(cross(cur), label, domainLabel, ttl); err != nil {
			panic("nslogic: " + err.Error())
		}
	}
	if frozen {
		nsdata.SetNameFrozen(cross(cur), label, domainLabel, true)
	}
	bumpRestored(cur, 1)
}

/*
RestoreNames replays many names in ONE transaction.

WHY A BLOB AND NOT A LOOP OF CALLS. A restore is done in one sitting
against a clock: the window is bounded and the people whose names are
missing are watching. One transaction per name is one signature per
name, and at a few hundred names that is an afternoon of clicking during
which a single mistimed refresh loses the thread. The compact form here
is unpleasant to read and it is the difference between a restore that
gets finished and one that gets abandoned half way.

The format is records separated by "|", fields separated by ",":

	label,domain,owner,registered,expires,ttl,frozen,isNFT

Neither a label nor a domain may contain "," or "|" — the character set
is enforced at registration — and an address contains neither, so the
split is unambiguous. tools/snapshot.js writes the JSON this is built
from; see tools/restore-blob.js for the conversion.

It stops at the first bad record and panics, taking the whole
transaction with it. That is deliberate: a partial batch that silently
skipped four names would leave four people without theirs and nothing
anywhere saying which four.
*/
func RestoreNames(cur realm, blob string) int {
	assertRestoring(cur)
	if blob == "" {
		panic("nslogic: nothing to restore")
	}
	recs := strings.Split(blob, "|")
	if len(recs) > 50 {
		panic("nslogic: at most 50 records per call, or the transaction " +
			"runs out of gas half way and it is unclear what landed")
	}
	done := 0
	for i, rec := range recs {
		if rec == "" {
			continue
		}
		r := parseRestoreRecord(rec, i)
		if nsdata.NameExists(r.label, r.domain) {
			panic("nslogic: record " + strconv.Itoa(i) + " (" + r.label + "*" + r.domain +
				") already exists; restore never overwrites a live record")
		}
		if err := nsdata.RegisterNameRecord(cross(cur), r.label, r.domain, r.owner, r.registered, r.isNFT); err != nil {
			panic("nslogic: record " + strconv.Itoa(i) + ": " + err.Error())
		}
		nsdata.SetNameExpiryRecord(cross(cur), r.label, r.domain, r.expires)
		if r.ttl != 0 {
			if err := nsdata.SetNameTTLRecord(cross(cur), r.label, r.domain, r.ttl); err != nil {
				panic("nslogic: record " + strconv.Itoa(i) + ": " + err.Error())
			}
		}
		if r.frozen {
			nsdata.SetNameFrozen(cross(cur), r.label, r.domain, true)
		}
		done++
	}
	bumpRestored(cur, int64(done))
	return done
}

// restoreRec is one parsed line of the blob.
type restoreRec struct {
	label, domain     string
	owner             address
	registered        int64
	expires, ttl      int64
	frozen, isNFT     bool
}

/*
parseRestoreRecord reads one record and refuses anything it is not sure
about.

EVERY CHECK HERE IS A PANIC AND NOT A SKIP. The blob is machine-written
from a snapshot, so a malformed record does not mean "this one name is
odd", it means the file is not what it was believed to be — and the
worst outcome available is a restore that appears to succeed while
quietly dropping the records it could not read. Somebody would find out
months later when one person asked where their name went.
*/
func parseRestoreRecord(rec string, i int) restoreRec {
	f := strings.Split(rec, ",")
	if len(f) != 8 {
		panic("nslogic: record " + strconv.Itoa(i) + " has " +
			strconv.Itoa(len(f)) + " fields, expected 8 " +
			"(label,domain,owner,registered,expires,ttl,frozen,isNFT)")
	}
	if f[0] == "" || f[1] == "" {
		panic("nslogic: record " + strconv.Itoa(i) + " has no name")
	}
	out := restoreRec{
		label:      f[0],
		domain:     f[1],
		owner:      address(f[2]),
		registered: mustSecs(f[3], i, "registered"),
		expires:    mustSecs(f[4], i, "expires"),
		ttl:        mustSecs(f[5], i, "ttl"),
		frozen:     f[6] == "1",
		isNFT:      f[7] == "1",
	}
	if !out.owner.IsValid() {
		panic("nslogic: record " + strconv.Itoa(i) + " has an invalid owner address")
	}
	if out.registered <= 0 || out.expires <= 0 {
		panic("nslogic: record " + strconv.Itoa(i) + " is missing its original dates")
	}
	// An expiry before the registration is not a record, it is a
	// corruption, and restoring it would create a name that was already
	// reclaimable the day it was bought.
	if out.expires < out.registered {
		panic("nslogic: record " + strconv.Itoa(i) + " expires before it was registered")
	}
	return out
}

func mustSecs(s string, i int, what string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v < 0 {
		panic("nslogic: record " + strconv.Itoa(i) + " has a bad " + what)
	}
	return v
}

// RestoreNameField and RestoreDomainField put back a record's extension
// keys — profiles, cross-chain addresses, tier markers, and a domain's
// pricing rules. Separate calls because the extension slot has no fixed
// shape by design, which is the same reason the snapshot captures it by
// enumeration rather than by schema.
func RestoreNameField(cur realm, label, domainLabel, key, value string) {
	assertRestoring(cur)
	if err := nsdata.SetNameExtraRecord(cross(cur), label, domainLabel, key, value); err != nil {
		panic("nslogic: " + err.Error())
	}
}

func RestoreDomainField(cur realm, label, key, value string) {
	assertRestoring(cur)
	if err := nsdata.SetDomainExtraRecord(cross(cur), label, key, value); err != nil {
		panic("nslogic: " + err.Error())
	}
}

// RestoreGlobal puts back the vault's global slot — where the default
// price, the referral tiers and the seasonal card effects live.
//
// It refuses to write the restore keys themselves. Without that, a
// snapshot taken while a window was open would, on being replayed,
// cheerfully restore the open window along with everything else — and a
// seal that a backup file can undo is not a seal.
func RestoreGlobal(cur realm, key, value string) {
	assertRestoring(cur)
	if key == keyRestore || key == keyRestoredCount {
		panic("nslogic: the restore mechanism does not restore itself")
	}
	if err := nsdata.SetGlobalRecord(cross(cur), key, value); err != nil {
		panic("nslogic: " + err.Error())
	}
}

// RestorePrimary puts back reverse resolution — which name an address
// answers to. Registration already sets this for an owner who had none,
// so this exists for the owners who had chosen a different one.
func RestorePrimary(cur realm, owner address, label, domainLabel string) {
	assertRestoring(cur)
	if err := nsdata.SetPrimaryRecord(cross(cur), owner, label, domainLabel); err != nil {
		panic("nslogic: " + err.Error())
	}
}
