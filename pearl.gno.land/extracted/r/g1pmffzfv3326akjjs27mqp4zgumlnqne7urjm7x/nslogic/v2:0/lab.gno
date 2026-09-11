package nslogic

import (
	"strconv"
	"strings"
	"time"

	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsdata/v1"
)

/*
BACKDATED NAMES, ON A REAL CHAIN, WITHOUT A BACKDOOR.

THE PROBLEM. Every expiry rule here is a function of a date, and every
date in this registry is a few weeks old. Live, in grace, and lapsed past
recovery are three different sets of behaviour — what renders, what can
be sold, what can be reclaimed, what the marketplace refuses — and only
the first has ever been seen. Waiting a year to find out is not a test
plan, and finding out on mainnet a year after launch is the outcome this
exists to prevent.

WHY NOT RestoreNames. Because it refuses, and it is right to. OpenRestore
panics on a populated vault:

    if d, n, _, _ := nsdata.Sizes(); d != 0 || n != 0 { panic(...) }

That guard was added for a specific reason recorded in restore.gno —
RestoreNameField can write any extension key on any EXISTING name, which
includes the payment addresses a name's pay page renders, and that is a
way to redirect somebody's incoming money with only the admin key. The
door is shut on any chain that holds records. It should stay shut, and
wanting test data is not a reason to widen it.

WHAT THIS IS INSTEAD. One function that moves an expiry, and it refuses
to touch anything outside a single domain that the admin has explicitly
nominated as the lab. Set no lab domain and this realm cannot move an
expiry at all — which is the state mainnet ships in, and the state it
stays in unless somebody deliberately changes it and says so on chain.

WHY THAT IS ENOUGH OF A GUARD. The admin can already deploy a logic realm
that does anything, so this grants no power that did not exist. What it
buys is that the power is NAMED, SCOPED and VISIBLE: LabDomain() is a
public read, so anybody can check that no lab is set, and every name this
can reach is under one extension that everybody can see and that
DeleteDomain removes in a call.

THE LAB DOMAIN IS NOT SPECIAL TO THE VAULT. It is an ordinary domain,
registered the ordinary way. Nothing about a name under it is fake — the
records, the artwork, the marketplace, the grace arithmetic are all the
real thing. The only unusual act is an admin moving a date, which is the
one thing a testnet cannot do by waiting.
*/

const keyLab = "labdomain"

// LabDomain is the domain that SetLabExpiry may touch, or "" when there
// is none — which must be the case on mainnet. A public read, so the
// claim above is checkable by anybody rather than asserted here.
func LabDomain() string { return nsdata.GetGlobal(keyLab) }

// SetLabDomain nominates a domain as the lab, or clears it with "".
//
// The domain must already exist, so the nomination cannot be made
// speculatively against a name somebody registers later.
func SetLabDomain(cur realm, label string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	label = strings.TrimSpace(label)
	if label == "" {
		setGlobal(cur, keyLab, "")
		return
	}
	if !nsdata.DomainExists(label) {
		panic("nslogic: no such domain — register it before nominating it as the lab")
	}
	setGlobal(cur, keyLab, label)
}

/*
SetLabExpiry moves one name's expiry to an absolute unix time.

It refuses outside the lab domain, and it refuses when no lab is set. The
two checks are separate on purpose: an empty lab must not match an empty
domain argument and quietly become a wildcard.

An expiry may be set into the past — that is the entire point. What it
may not be is before the name was registered, because that is not a state
the ordinary rules can produce and testing against an impossible record
teaches nothing.
*/
func SetLabExpiry(cur realm, label, domainLabel string, expires int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)

	lab := LabDomain()
	if !labScopeOK(lab, domainLabel) {
		if lab == "" {
			panic("nslogic: no lab domain is set; SetLabDomain first, and never on mainnet")
		}
		panic("nslogic: " + domainLabel + " is not the lab domain (" + lab + ")")
	}
	if !nsdata.NameExists(label, domainLabel) {
		panic("nslogic: no such name — register it first, then move its date")
	}
	_, registered, _, _, _, _ := nsdata.GetNameInfo(label, domainLabel)
	if !labDateOK(registered, expires) {
		panic("nslogic: that would expire the name before it was registered, " +
			"which the ordinary rules cannot produce")
	}
	nsdata.SetNameExpiryRecord(cross(cur), label, domainLabel, expires)
}

// The scoping rule, alone and testable. Kept as its own function
// because the two conditions must stay SEPARATE: folded into one, an
// unset lab would match an unnamed domain and the guard becomes a
// wildcard pointing at every name in the registry.
func labScopeOK(lab, domainLabel string) bool {
	if lab == "" {
		return false
	}
	return domainLabel == lab
}

// An expiry may be in the past — that is the point — but not before the
// name existed, which is not a state the ordinary rules can produce.
func labDateOK(registered, expires int64) bool {
	return expires > 0 && expires >= registered
}

/*
RegisterLabName creates a name in the lab with a registration date in the
PAST, and an expiry wherever the test needs it.

FOUND ON THE FIRST RUN ON PEARL. SetLabExpiry moves an expiry but refuses
to put it before the registration date — and every lab name had been
registered minutes before its date was moved. So grace and lapsed could
not be produced at all, and neither could tenure: the metal ladder reads
years held from the registration date, which nothing could move.

No registry change is needed, and that is the reason this is shaped the
way it is. nsdata.RegisterNameRecord already takes `now` from its caller —
it is how a trusted logic realm records the moment of registration — so a
lab name is registered at a moment `heldDays` ago and its expiry set
after. A logic deploy, not a new registry.

Same fence as SetLabExpiry: admin only, the nominated lab domain only, and
never an expiry before the registration it now has. `paid` false makes a
free-tier name, held on the ledger like any other.
*/
func RegisterLabName(cur realm, label string, heldDays, expiresInDays int64, paid bool) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	lab := LabDomain()
	if !labScopeOK(lab, lab) {
		panic("nslogic: no lab domain is set; SetLabDomain first, and never on mainnet")
	}
	if heldDays < 0 || heldDays > 36500 {
		panic("nslogic: heldDays must be 0-36500")
	}
	validateLabel(label)
	now := time.Now().Unix()
	registered := now - heldDays*86400
	expires := now + expiresInDays*86400
	if !labDateOK(registered, expires) {
		panic("nslogic: that would expire the name before it was registered, " +
			"which the ordinary rules cannot produce")
	}
	if err := nsdata.RegisterNameRecord(cross(cur), label, lab, cur.Previous().Address(), registered, paid); err != nil {
		panic(err)
	}
	nsdata.SetNameExpiryRecord(cross(cur), label, lab, expires)
}

// SetLabExpiryDays is the form a script actually wants: days from now,
// negative for the past. "expired eleven days ago" is a sentence; the
// unix time it corresponds to is not, and computing it in bash is how a
// test set ends up quietly one day out.
func SetLabExpiryDays(cur realm, label, domainLabel string, days int64) {
	SetLabExpiry(cur, label, domainLabel, time.Now().Unix()+days*86400)
}

/*
LabReport answers, for every name in the lab, what the registry thinks
its state is RIGHT NOW — read from the same GetGracePeriod the rest of
the realm uses rather than recomputed here.

It exists because the interesting failures are disagreements: the card
says lapsed, the marketplace still lists it, the reclaim path still
refuses. One line per name, so a script can diff what the chain believes
against what the site drew.

	label,expires,daysLeft,state
*/
func LabReport() string {
	lab := LabDomain()
	if lab == "" {
		return ""
	}
	now := time.Now().Unix()
	grace := nsdata.GetGracePeriod()

	var out []string
	after := ""
	for {
		keys, next := nsdata.ExportNames(lab, after, 200)
		if keys == "" {
			break
		}
		for _, k := range strings.Split(keys, ",") {
			k = strings.TrimSpace(k)
			if k == "" {
				continue
			}
			// THE STORAGE KEY IS domain*label, the reverse of a token id.
			// This has been got backwards more than once in this project.
			star := strings.Index(k, "*")
			if star < 0 {
				continue
			}
			label := k[star+1:]
			_, _, expires, _, _, _ := nsdata.GetNameInfo(label, lab)
			state := "LIVE"
			switch {
			case now >= expires+grace:
				state = "LAPSED"
			case now >= expires:
				state = "GRACE"
			}
			out = append(out, label+","+strconv.FormatInt(expires, 10)+","+
				strconv.FormatInt((expires-now)/86400, 10)+","+state)
		}
		if next == "" || next == after {
			break
		}
		after = next
	}
	return strings.Join(out, ";")
}
