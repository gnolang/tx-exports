package nslogic

import (
	"strconv"
	"strings"

	"gno.land/r/nym-mnsrehearsal001/nsdata/v2"
)

// assertIsAdmin reads nsdata.GetAdmin() fresh every call — correct even
// immediately after a TransferAdmin, and correct for a freshly-deployed
// logic realm with no local state of its own to go stale.
//
// Note: admin authority to swap WHICH realm is trustedLogic, or to
// transfer admin itself, is deliberately NOT exposed here — those live
// only in nsdata's own admin.gno, callable solely by a direct wallet
// call from the current admin address, never proxied through logic.
// That's the one part of the system a compromised or buggy logic realm
// cannot touch.
func assertIsAdmin(cur realm) {
	if cur.Previous().Address() != nsdata.GetAdmin() {
		panic("nslogic: restricted to project admin")
	}
}

// SetLabelPattern no longer changes anything, and refuses anything but
// the rule this realm actually implements.
//
// It used to compile an arbitrary regex and store it, with validateLabel
// reading it back. That flexibility cost 15 GNOT of permanent storage
// per deploy — see the measurements in validate.gno — for a rule that
// has never changed and should not change casually.
//
// It is kept rather than deleted so that an admin who reaches for it
// gets told what happened instead of a "function not found". And it
// refuses a different pattern rather than accepting one it will not
// enforce: a stored string describing rules the code does not apply is
// the exact silent divergence the caching version was written to avoid.
func SetLabelPattern(cur realm, pattern string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetLabelPattern", "pattern", pattern)
	if pattern != labelRule {
		panic("nslogic: the label rule is fixed in this realm (" + labelRule +
			"). Changing it means deploying a new logic realm — which is deliberate, " +
			"because a stored pattern the code does not enforce is worse than no setting at all.")
	}
	nsdata.SetLabelPatternRecord(cross(cur), pattern)
}

func SetLabelLengthLimits(cur realm, minLen, maxLen int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetLabelLengthLimits", "min", fmtI(minLen), "max", fmtI(maxLen))
	if minLen < 1 || maxLen < minLen {
		panic("nslogic: invalid length bounds")
	}
	nsdata.SetLabelLengthRecord(cross(cur), minLen, maxLen)
}

// SetDefaultNamePrice sets the fallback price in micro-USD, used by any
// domain that has not set its own base. BOUNDED (timelock.gno): a raise up
// to four times every ten minutes, a cut up to 25% once an hour, or a
// timelocked proposal for anything else.
func SetDefaultNamePrice(cur realm, microUsd int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetDefaultNamePrice", "microUsd", fmtInt(microUsd))
	if microUsd < 0 || microUsd > maxPriceUSD {
		panic("nslogic: a price is 0.." + strconv.FormatInt(maxPriceUSD, 10) + " micro-USD")
	}
	v := strconv.FormatInt(microUsd, 10)
	old := DefaultPriceUSD()
	authorizeTweak(cur, keyDefaultPrice, old, microUsd, microUsd > old, actionID("SetDefaultNamePrice", v))
	setGlobal(cur, keyDefaultPrice, v)
}

// SetUsdRate records how many ugnot one USD buys — the bridge between
// the USD price list and settlement on this chain.
//
// It is a MANUAL rate, not a market feed: it sits where it was last
// written. A stale rate during a sharp move sells names at the wrong
// price, and no amount of contract logic fixes that — keeping it current
// is an operational duty. Isolated as one global so a future logic realm
// can swap in a real oracle without touching the vault or restating a
// single price.
//
// BOUNDED (timelock.gno): a rate of 1 ugnot to the dollar used to be one
// call away from selling every name for dust. ASYMMETRIC (Ely,
// 2026-10-16): a higher rate — GNOT fell, names cost more GNOT — moves up
// to four times every ten minutes, so a 75% crash is followed in one
// update; a lower rate — the direction that sells names cheap — moves at
// most 25%, once an hour. Anything larger is a timelocked proposal.
//
// THE KEEPER may call this too (keeper.gno), and nothing else: the same
// bound and the same hourly slot, never the timelock, and KeeperAction on
// every move. Anybody who is neither gets the admin refusal, as before.
func SetUsdRate(cur realm, ugnotPerUsd int64) {
	assertNoSend(cur)
	if cur.Previous().Address() != nsdata.GetAdmin() {
		keeperSetRate(cur, ugnotPerUsd)
		return
	}
	assertIsAdmin(cur)
	emitAdmin(cur, "SetUsdRate", "ugnotPerUsd", fmtInt(ugnotPerUsd))
	if ugnotPerUsd <= 0 || ugnotPerUsd > maxRate {
		panic("nslogic: a rate is 1.." + strconv.FormatInt(maxRate, 10) + " ugnot per USD")
	}
	v := strconv.FormatInt(ugnotPerUsd, 10)
	old := RateUgnotPerUsd()
	authorizeTweak(cur, keyRate, old, ugnotPerUsd, ugnotPerUsd > old, actionID("SetUsdRate", v))
	setGlobal(cur, keyRate, v)
}

// SetTermLength / SetGracePeriod retune the lifecycle itself. Both were
// hardcoded constants in the vault until 2026-08-21 — meaning the 1-year
// term and 90-day grace could never have been changed, on a realm that
// is never redeployed. There was no reason to accept that.
// maxLifecycleDays bounds both setters. time.Duration is int64
// NANOSECONDS, so `days * 24h` overflows above ~106,751 days and wraps to
// a NEGATIVE duration — which would install a negative term and brick
// every registration and renewal in the registry. Guarding the input is
// what keeps the multiplication in range.
const maxLifecycleDays = 36500 // 100 years

// BOTH ARE TIMELOCKED (timelock.gno). A grace period of zero made every
// name in grace reclaimable by anybody on the spot — owners who could
// still have renewed lost their names to whoever registered first — and a
// term change reprices every renewal and moves every holder's tenure.
func SetTermLength(cur realm, days int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetTermLength", "days", fmtInt(days))
	if days <= 0 || days > maxLifecycleDays {
		panic("nslogic: term out of range (1..36500 days)")
	}
	term := days * 24 * 60 * 60
	// Keep gracePeriod <= termLength. Anchoring a renewal to the previous
	// due date is only coherent while a renewal cannot happen more than
	// one full term after it; the vault clamps forward defensively, but
	// the combination should not be reachable in the first place.
	if nsdata.GetGracePeriod() > term {
		panic("nslogic: term must be at least the current grace period")
	}
	requireAction(cur, actionID("SetTermLength", strconv.FormatInt(days, 10)))
	nsdata.SetTermLengthRecord(cross(cur), term)
}

func SetGracePeriod(cur realm, days int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetGracePeriod", "days", fmtInt(days))
	if days < 0 || days > maxLifecycleDays {
		panic("nslogic: grace period out of range (0..36500 days)")
	}
	grace := days * 24 * 60 * 60
	if grace > nsdata.GetTermLength() {
		panic("nslogic: grace period may not exceed the term length")
	}
	requireAction(cur, actionID("SetGracePeriod", strconv.FormatInt(days, 10)))
	nsdata.SetGracePeriodRecord(cross(cur), grace)
}

// SetTokenURIBase re-points TokenURI at a different renderer, so the NFT
// artwork can be replaced without touching the vault.
func SetTokenURIBase(cur realm, base string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetTokenURIBase", "base", base)
	nsdata.SetTokenURIBaseRecord(cross(cur), base)
}

func SetExtraLimits(cur realm, keyLen, valueLen, entries int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetExtraLimits", "keyLen", fmtI(keyLen), "valueLen", fmtI(valueLen), "entries", fmtI(entries))
	// NEVER BELOW WHAT THIS REALM ITSELF WRITES: the vault's own defaults
	// (32-byte keys, 512-byte values, 24 entries). One instant call to a
	// tiny limit used to make every later global write revert, the keeper's
	// rate and the instant revocations among them (re-audit L-2).
	if keyLen < minExtraKeyLen || valueLen < minExtraValueLen || entries < minExtraEntries {
		panic("nslogic: extra limits are at least " + fmtI(minExtraKeyLen) + " / " + fmtI(minExtraValueLen) +
			" / " + fmtI(minExtraEntries) + ", the sizes this realm writes")
	}
	nsdata.SetExtraLimitsRecord(cross(cur), keyLen, valueLen, entries)
}

const (
	minExtraKeyLen   = 32
	minExtraValueLen = 512
	minExtraEntries  = 24
)

// SetGlobalEntryLimit sets how many keys the vault's globals may hold —
// its own cap now, apart from the per-record extras SetExtraLimits bounds.
func SetGlobalEntryLimit(cur realm, entries int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetGlobalEntryLimit", "entries", fmtI(entries))
	if entries < 1 || entries > 1024 {
		panic("nslogic: the globals cap must be 1-1024")
	}
	nsdata.SetGlobalEntryLimitRecord(cross(cur), entries)
}

// SetAccountLimits bounds the vault's per-address store: field name,
// value, and fields per address. Small numbers, because whoever's
// transaction writes a field pays for it.
func SetAccountLimits(cur realm, keyLen, valueLen, entries int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetAccountLimits", "keyLen", fmtI(keyLen), "valueLen", fmtI(valueLen), "entries", fmtI(entries))
	// Never below what this realm writes (the vault's defaults, 16/128/8):
	// a tiny limit refused every later grant, redemption and referral
	// count, deletes included — L-2's bug on the per-address store
	// (review follow-up).
	if keyLen < 16 || keyLen > 64 || valueLen < 128 || valueLen > 1024 || entries < 8 || entries > 64 {
		panic("nslogic: account limits must be 16-64 / 128-1024 / 8-64")
	}
	nsdata.SetAccountLimitsRecord(cross(cur), keyLen, valueLen, entries)
}

/*
SetMarketFee is nsmarket's fee control, living here because this is the
realm the vault trusts.

nsmarket.SetFee could never work: it wrote through nsdata.SetGlobalRecord
from a realm deliberately outside the trusted set, so it passed its own
admin check and then panicked inside the vault for every caller. Rather
than grant nsmarket vault privileges — which would surrender the property
that realm is built around — the setter moved to the realm that already
has the grant, and the validation moved with it.

The spec grammar is nsmarket's, restated here rather than imported so
this realm does not take a dependency on the marketplace to set a number:
an amount in ugnot ("1000000"), or a percentage ("%2.5"); "0" for none,
because "" removes the key and nsmarket then charges its default of one
GNOT. A malformed spec would otherwise be read on every sale and resolve
silently to zero.

A CHANGE THAT COULD RAISE THE FEE IS TIMELOCKED. The fee is read at sale
time, so a raise lands on listings sellers made under the old one — up to
half of their sale, moved to the treasury, with no notice. A timelocked
raise is the notice: sellers see ActionProposed and may unlist. Lowering
it, or switching it off, stays instant.
*/
func SetMarketFee(cur realm, spec string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetMarketFee", "spec", spec)
	assertValidFeeSpec(spec)
	spec = strings.TrimSpace(spec)
	if feeCouldRise(nsdata.GetGlobal(keyMarketFee), spec) {
		requireAction(cur, actionID("SetMarketFee", spec))
	}
	setGlobal(cur, keyMarketFee, spec)
}

const (
	keyMarketFee = "marketfee"
	// nsmarket's fee when the global is unset: one GNOT, flat. Restated
	// rather than imported, like the grammar, so this realm takes no
	// dependency on the marketplace to set a number.
	defaultMarketFee = "1000000"
)

// feeCouldRise reports whether moving from the stored spec `old` to `next`
// could raise the fee on any sale. Both are read the way nsmarket reads
// them: unset means the default. A move to zero never rises; a change of
// kind — flat to percentage or back — rises on some price, so it counts.
func feeCouldRise(old, next string) bool {
	of, ob := feeParts(old)
	nf, nb := feeParts(next)
	switch {
	case nf == 0 && nb == 0:
		return false
	case of == 0 && ob == 0:
		return true
	case ob == 0 && nb == 0:
		return nf > of
	case of == 0 && nf == 0:
		return nb > ob
	}
	return true
}

// feeParts splits a spec into (flat ugnot, basis points), the way
// nsmarket.parseFee does; unset is the default fee, and an unreadable spec
// is zero — which is also how nsmarket charges it.
func feeParts(spec string) (flat, bps int64) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		spec = defaultMarketFee
	}
	if !strings.HasPrefix(spec, "%") {
		n, err := strconv.ParseInt(spec, 10, 64)
		if err != nil || n < 0 {
			return 0, 0
		}
		return n, 0
	}
	body := spec[1:]
	whole, frac := body, ""
	if dot := strings.Index(body, "."); dot >= 0 {
		whole, frac = body[:dot], body[dot+1:]
	}
	w, err := strconv.ParseInt("0"+whole, 10, 64)
	if err != nil {
		return 0, 0
	}
	bps = w * 100
	if frac != "" {
		f, err := strconv.ParseInt("0"+frac, 10, 64)
		if err != nil || len(frac) > 1 {
			return 0, 0
		}
		bps += f * 10
	}
	return 0, bps
}

// assertValidFeeSpec mirrors nsmarket.parseFee. Percentages are carried
// as basis points so a fee is expressible without floating point
// anywhere near money.
func assertValidFeeSpec(spec string) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return
	}
	if !strings.HasPrefix(spec, "%") {
		n, err := strconv.ParseInt(spec, 10, 64)
		if err != nil || n < 0 {
			panic("nslogic: a fee is an amount in ugnot or a percentage like %2.5 — got " + spec)
		}
		return
	}
	body := spec[1:]
	whole, frac := body, ""
	if dot := strings.Index(body, "."); dot >= 0 {
		whole, frac = body[:dot], body[dot+1:]
	}
	// ONE decimal, matching nsmarket.parseFee exactly. I wrote two here
	// first, which made this validator MORE permissive than the parser
	// that has to read the value back — and a spec nsmarket refuses is
	// read as a zero fee on every sale, silently, forever. A validator
	// looser than its consumer is worse than no validator: it converts a
	// rejected input into a silent revenue leak.
	if len(frac) > 1 {
		panic("nslogic: a fee percentage carries at most one decimal — got " + spec)
	}
	for _, part := range []string{whole, frac} {
		for i := 0; i < len(part); i++ {
			if part[i] < '0' || part[i] > '9' {
				panic("nslogic: a fee percentage must be digits — got " + spec)
			}
		}
	}
	if whole == "" && frac == "" {
		panic("nslogic: a fee percentage needs a number — got " + spec)
	}
	// Basis points the same way parseFee computes them: whole*100 plus
	// one tenth-digit worth ten. Not two digits, and not a 100% ceiling
	// — nsmarket caps at maxFeeBps, which is 50%.
	w, _ := strconv.ParseInt("0"+whole, 10, 64)
	bp := w * 100
	if frac != "" {
		f, _ := strconv.ParseInt("0"+frac, 10, 64)
		bp += f * 10
	}
	if bp <= 0 || bp > 5000 {
		panic("nslogic: a fee percentage must be above zero and at most 50 — got " + spec)
	}
}

// SetGlobal writes an arbitrary project-wide key into the vault's
// package-level extension slot — the escape hatch for global state that
// does not exist yet, and for keys other realms read (cardfx). It refuses
// every key a setter here owns: the escape hatch used to walk round every
// bound and timelock on them. See managedGlobal.
func SetGlobal(cur realm, key, value string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetGlobal", "key", key, "value", value)
	if managedGlobal(key) {
		panic("nslogic: " + key + " has its own setter, with its own rules; use that")
	}
	setGlobal(cur, key, value)
}

func setGlobal(cur realm, key, value string) {
	/* THE RESTORE SEAL IS NOT AN ORDINARY GLOBAL.
	   restore.gno says sealing is "IRREVERSIBLE… There is no argument
	   that unseals it". One admin call writing key "restore" used to
	   reopen it. The vault now refuses both keys through its general
	   setter and refuses to change a seal through its reserved one, so a
	   logic swap cannot drop the guard; this check stays so the refusal
	   names the right door. */
	if key == keyRestore || key == keyRestoredCount {
		panic("nslogic: " + key + " is written by the restore machinery, not by SetGlobal")
	}
	if err := nsdata.SetGlobalRecord(cross(cur), key, value); err != nil {
		panic(err)
	}
}

// SetTreasury moves the revenue-receiving role — independent of
// nsdata's TransferAdmin, same reasoning as the original build's
// admin/treasury separation.
//
// TIMELOCKED. It took effect at once and said nothing, so a stolen admin
// key redirected every later sale — names, renewals, skins, market fees —
// in one call (audit M4). Now it is announced and waits, and recovery can
// cancel it.
func SetTreasury(cur realm, newTreasury address) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetTreasury", "addr", newTreasury.String())
	if !newTreasury.IsValid() {
		panic("nslogic: invalid treasury address")
	}
	requireAction(cur, actionID("SetTreasury", newTreasury.String()))
	nsdata.SetTreasuryRecord(cross(cur), newTreasury)
}

// SelfAddress reports this deployed realm's own address — needed once,
// at wiring time, so admin knows what to pass to
// nsdata.ProposeTrustedLogicGrant.
func SelfAddress(cur realm) address {
	return cur.Address()
}
