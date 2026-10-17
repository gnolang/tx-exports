package nslogic

import (
	"math"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/nym-mnsrehearsal001/nsdata/v1"
)

/*
THE ADMIN KEY IS NOT THE REGISTRY ANY MORE.

Until this file, every admin call here was instant, and an audit used them
to take a paid name from its holder, make every name in grace reclaimable,
delete live names and redirect all revenue — in one transaction, with a
48-hour timelock in force and nothing ever proposed (audit H-1). The
vault's timelock guarded only the trust set and the roles.

So the calls are now in three classes:

	TIMELOCKED — anything that destroys or moves names or money, or
	rewrites pricing rules a single edit could zero: DeleteDomain,
	SetTermLength, SetGracePeriod, SetTreasury, ReassignDomain,
	UnfreezeName and UnfreezeNames (up to 64 names behind one action),
	SetGranter and SetKeeper (naming one; removing stays
	instant), SetDomainLengthRules, SetDomainNameOverrides,
	SetGlobalLengthRules, SetPremiumNames, OpenRestore, and SetMarketFee
	whenever the change could raise a fee. The admin proposes the exact call in the vault —
	nsdata.ProposeAction("<Function> <arg> <arg>…") — waits out the
	vault's delay, during which recovery can cancel it, and then makes
	the call, which spends the proposal. A refusal names the exact id to
	propose.

	BOUNDED — the price levers that must move day to day: SetUsdRate,
	SetDefaultNamePrice, SetDomainBasePrice, SetClaimMaxPrice. Instant
	inside a bound that depends on WHICH WAY the change moves a name's
	cost (Ely, 2026-10-16); anything bigger, or sooner, goes through the
	timelock the same way.

	  CHEAPER — the direction a thief needs: the rate down, a price cut,
	  the credit cap raised. At most cheapMaxPct of the current value at
	  once, at most once per cheapCooldown (an hour). A stolen key can
	  move each lever a quarter an hour, in public — the rate and a base
	  price compound, so a name's price can fall by about 44% in the first
	  hour (0.75 x 0.75), and to 0.5625^h of list after h hours — rather
	  than take every name for dust in one block. Two levers per name, not
	  three: an unpriced domain's first own price shares the default's
	  clocks (authorizeTweakOn).

	  DEARER — the rate up after GNOT crashes, a price raised, the credit
	  cap cut. Up to dearMaxFactor at once (four times: GNOT falling 75%
	  is followed in ONE update), at most once per dearCooldown (ten
	  minutes). Its theft costs an outage — names too dear to buy — never
	  a name or a coin. Which is only true while no lever is tied to
	  another: the credit cap used to fall back to the default price, so a
	  dearer default walked the cap the cheap way, four times every ten
	  minutes (re-audit 2026-10-16, H-1). It stands alone now, and unset it
	  covers nothing (credits.gno).

	Each direction keeps its own clock, so a dearer step in between does
	not reopen the cheaper hour. The guardian bot revoking the logic realm
	on the first AdminAction it did not expect is what keeps that hour
	short. The KEEPER (keeper.gno) moves the rate inside the same bounds,
	on the same clocks as the admin, and never through the timelock.

	INSTANT — everything that cannot take anything from anybody: freezing
	(the protective direction), opening and closing domains, the block
	list, free-tier and credit grants, limits, TTLs, art, and ClearKeeper.

THE CLOCK IS THE VAULT'S, deliberately: a new logic realm cannot shorten a
delay it does not hold, and the delay itself only changes through the
vault's own timelock.
*/

// actionID is the canonical name of one call: the function and its
// arguments, separated by single spaces, an empty argument written "".
// It is what the admin proposes and what the call spends, so a proposal
// authorizes exactly one change with exactly those arguments.
func actionID(fn string, args ...string) string {
	id := fn
	for _, a := range args {
		if a == "" {
			a = `""`
		}
		if strings.ContainsAny(a, " \t\n\r") {
			panic("nslogic: an argument to a timelocked call may not contain spaces: " + a)
		}
		id += " " + a
	}
	return id
}

// assertActionReady explains, before anything is written, why a
// timelocked call cannot run yet. The vault's ConsumeAction is the
// authority; this only makes the refusal say what to do.
func assertActionReady(id string) {
	if nsdata.EvictionPending() {
		panic("nslogic: recovery is replacing the admin; timelocked changes wait until that lands, and the admin's proposals die with it")
	}
	at, expires, _ := nsdata.GetAction(id)
	now := time.Now().Unix()
	switch {
	case at == 0:
		panic("nslogic: this change waits out the vault timelock. Propose exactly `" + id +
			"` with nsdata.ProposeAction from the admin key, then call again once it matures; recovery may cancel it until then")
	case now < at:
		panic("nslogic: `" + id + "` is proposed and matures at unix " + strconv.FormatInt(at, 10))
	case now >= expires:
		panic("nslogic: `" + id + "` expired at unix " + strconv.FormatInt(expires, 10) + "; propose it again")
	}
	if !nsdata.ActionReady(id) {
		panic("nslogic: `" + id + "` was proposed by a previous admin; propose it again")
	}
}

// requireAction lets a timelocked call through only on a matured proposal
// for exactly this call, and spends it.
func requireAction(cur realm, id string) {
	assertActionReady(id)
	nsdata.ConsumeAction(cross(cur), id)
}

// -- bounded instant changes --

const (
	// A move that makes names CHEAPER (the rate down, a price cut, the
	// credit cap raised) is at most this much of the current value, and a
	// setting moves that way instantly at most once per cheapCooldown.
	cheapMaxPct   = 25
	cheapCooldown = 60 * 60

	// A move that makes names DEARER may go up to dearMaxFactor times (or
	// down to 1/dearMaxFactor, for the credit cap) at once — four: GNOT
	// falling 75% is followed in one update — at most once per dearCooldown.
	dearMaxFactor = 4
	dearCooldown  = 10 * 60

	// The highest rate SetUsdRate accepts: a million GNOT to the dollar.
	// Like maxPriceUSD, a ceiling no real market reaches, low enough that
	// price times rate cannot overflow unnoticed (see NamePrice).
	maxRate = int64(1_000_000_000_000)
)

/*
lastTweak is the ONE piece of state this realm keeps: when each bounded
setting last moved, one clock per direction. Not a record — losing it
costs nothing but one early tweak — so it lives here rather than in the
vault, and a logic swap simply starts it empty.
*/
var lastTweak avl.Tree

func clockKey(setting string, dearer bool) string {
	if dearer {
		return setting + ":dear"
	}
	return setting + ":cheap"
}

/*
authorizeTweak lets a bounded setting move from `old` to `next` instantly
when the move stays inside its direction's bound and that direction's clock
has rested; otherwise it needs a matured proposal of `id`, which it spends.
`dearer` says whether the move makes names dearer — for the rate and the
prices that is a rise, for the credit cap a fall — and the caller, which
knows what its setting means, decides it. A move to or from zero is never
an instant step: a free domain, or a price restored from free, is a
decision.
*/
func authorizeTweak(cur realm, setting string, old, next int64, dearer bool, id string) {
	authorizeTweakOn(cur, []string{setting}, old, next, dearer, id)
}

/*
authorizeTweakOn is authorizeTweak for a move that rides more than one
clock: every clock named must have rested, and all of them are stamped.

An unpriced domain's base price IS the default, so its first price of its
own is measured against the default — after the default has already been
cut, on a clock of its own. Rate, default and domain then each took 25% in
one block: 0.75^3 of the price, 58% off, not the two levers (about 44%)
this file promises (re-audit 2026-10-16, L-1). So that first own price
rides the default's clocks too (domain.gno): in any hour, either the
default or an unpriced domain's first own price moves, never both.
*/
func authorizeTweakOn(cur realm, settings []string, old, next int64, dearer bool, id string) {
	if next == old {
		return
	}
	now := time.Now().Unix()
	if nsdata.ActionReady(id) {
		nsdata.ConsumeAction(cross(cur), id)
		for _, st := range settings {
			lastTweak.Set(clockKey(st, dearer), now)
		}
		return
	}
	setting := settings[0]
	if !withinStep(old, next, dearer) {
		panic("nslogic: " + stepRefusal(setting, old, next, dearer) +
			"; anything larger waits out the vault timelock: propose `" + id +
			"` with nsdata.ProposeAction and call again once it matures")
	}
	for _, st := range settings {
		if !clockRested(st, dearer, now) {
			panic("nslogic: " + restRefusal(st, dearer) +
				"; wait, or put this through the vault timelock: propose `" + id + "` with nsdata.ProposeAction")
		}
	}
	for _, st := range settings {
		lastTweak.Set(clockKey(st, dearer), now)
	}
}

// withinStep is the bound on its own. New values are capped (maxPriceUSD,
// maxRate); an old value stored before the caps, or by a restore, is not,
// so anything too large to multiply safely is simply not an instant step.
func withinStep(old, next int64, dearer bool) bool {
	if old <= 0 || next <= 0 || old > math.MaxInt64/100 || next > math.MaxInt64/100 {
		return false
	}
	if dearer {
		hi, lo := next, old
		if lo > hi {
			hi, lo = lo, hi
		}
		return hi <= lo*dearMaxFactor
	}
	d := next - old
	if d < 0 {
		d = -d
	}
	return d*100 <= old*cheapMaxPct
}

// inheritClocks gives `to` every last-move time of `from` that is later
// than its own, in both directions: a setting that starts out as another
// one's value starts on that one's clocks.
func inheritClocks(to, from string) {
	for _, dearer := range []bool{true, false} {
		f := lastTweak.Get(clockKey(from, dearer))
		if f == nil {
			continue
		}
		if t := lastTweak.Get(clockKey(to, dearer)); t == nil || t.(int64) < f.(int64) {
			lastTweak.Set(clockKey(to, dearer), f.(int64))
		}
	}
}

func clockRested(setting string, dearer bool, now int64) bool {
	rest := int64(cheapCooldown)
	if dearer {
		rest = dearCooldown
	}
	v := lastTweak.Get(clockKey(setting, dearer))
	return v == nil || now-v.(int64) >= rest
}

func stepRefusal(setting string, old, next int64, dearer bool) string {
	span := strconv.FormatInt(old, 10) + " to " + strconv.FormatInt(next, 10)
	if dearer {
		return setting + " may make names dearer by at most " + strconv.Itoa(dearMaxFactor) + "x at once (" + span + ")"
	}
	return setting + " may make names cheaper by at most " + strconv.Itoa(cheapMaxPct) + "% at once (" + span + ")"
}

func restRefusal(setting string, dearer bool) string {
	if dearer {
		return setting + " made names dearer less than ten minutes ago"
	}
	return setting + " made names cheaper less than an hour ago"
}

// LastTweak reports when a bounded setting last moved instantly in each
// direction (unix seconds, 0 for never), so the panel can say when the
// next step each way is due: dearer after ten minutes, cheaper after an hour.
func LastTweak(setting string) (dearer, cheaper int64) {
	if v := lastTweak.Get(clockKey(setting, true)); v != nil {
		dearer = v.(int64)
	}
	if v := lastTweak.Get(clockKey(setting, false)); v != nil {
		cheaper = v.(int64)
	}
	return dearer, cheaper
}

// -- keys only their own setters may write --

/*
managedGlobal reports whether SetGlobal must refuse a key, because a
setter in this realm owns it — bounded, timelocked or validated. The
escape hatch wrote any key, so it walked straight round every one of those
rules: SetGlobal("rateUgnotPerUsd", "1") was a one-call way to sell every
name for dust.
*/
func managedGlobal(key string) bool {
	switch key {
	case keyDefaultPrice, keyRate, keyMarketFee, keyGranter, keyKeeper, keyGlobalLens,
		keyRefCut, keyRefDisc, keyRefWin, keyMaxTerm, keyFreeMin, keyFreeMax,
		keyClaimEnd, keyClaimMax, keyRestore, keyRestoredCount, "labdomain":
		return true
	}
	return strings.HasPrefix(key, keyPremium) || strings.HasPrefix(key, blockKeyStem)
}

// managedDomainKey is the same rule for SetDomainField.
func managedDomainKey(key string) bool {
	switch key {
	case keyPrice, keyLens, keyNames, keyOpen, keyFreeDomain, keyMaxTerm:
		return true
	}
	return false
}
