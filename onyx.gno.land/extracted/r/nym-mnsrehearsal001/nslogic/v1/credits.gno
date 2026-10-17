package nslogic

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/r/nym-mnsrehearsal001/nsdata/v1"
)

/*
CREDITS: a free registration, granted to an address ahead of time.

WHY. Two plans need it (MAINNET.md §0):
  - the migration grant: every wallet that registered a name on testnet
    gets one free name on mainnet, of its own choosing;
  - onboarding: somebody who holds no GNOT at all is given a name, and
    the project registers it FOR them.

WHERE IT LIVES. In the vault's per-address store, never in this realm, so
a logic swap neither loses nor repeats anybody's credit — and not in
globals, which cannot hold an address-sized key at all.

THE RECORD is one field, "cr", holding "granted,used,expires,held,at":

	granted  credits issued in total. A grant SETS this number, it never
	         adds to it, so re-running a grant batch after people have
	         redeemed cannot hand anybody a second name;
	used     credits redeemed;
	expires  the unix second they lapse, 0 for none (the claim window
	         still bounds every credit);
	held     1: the name is minted with the free-tier hold — usable and
	         renewable, not sellable until upgraded at list price. Only a
	         grant made with sellable=false writes 1;
	at       the unix second of the grant (re-audit 2026-10-16, M-2), so
	         recovery can void what a stolen admin key granted
	         (nsdata.VoidGrantsSince) and the honest admin can grant again
	         what was legitimate. A record written before this field reads
	         as granted at 0.

AN INCIDENT CAN UNDO A GRANT. What a thief granted used to outlive its
eviction: the credits live in the vault, and nothing could touch them while
the logic was revoked and the registry paused, so the thief's wallets
redeemed in the block that unpaused it. Now the vault's incident switches
(nsdata incident.gno) hold: no credit is spent while the registry is
paused, while recovery's quarantine runs, or once recovery has voided the
time it was granted in; and the guardian's Disarm shuts the claim window.

SELLABLE BY DEFAULT (Ely, 2026-10-16). A credit buys a real name, minted
like a paid one and free to sell, unless the grant says otherwise: the
per-grant flag is `sellable`, and every caller passes true unless it means
to hand out a held name. The record keeps the hold bit, so its stored form
did not change; the API speaks in the direction the default runs.

WHO PAYS THE STORAGE DEPOSIT. Whoever SIGNS, and nobody else can. The
chain charges a call's storage deposit and its gas to the transaction's
signer (gno.land/pkg/sdk/vm keeper.go, lockStorageDeposit(ctx, caller,
...)); a realm cannot pay either on somebody's behalf, and this one holds
no coins to try. So there are two doors, and both spend the holder's
credit:

	RedeemCredit  the holder signs. The name costs nothing; the holder
	              pays the storage deposit (about 0.57 GNOT) and gas.
	RegisterFor   the admin or the granter signs and the project pays
	              both; the name goes to the holder. This is the only
	              path for a holder with no GNOT, who cannot sign at all.

WHAT A CREDIT BUYS. One ordinary registration at no price: any open
domain, any label the ordinary rules allow, up to a list price cap
(ClaimMaxPriceUSD) — the on-chain answer to MAINNET.md's "do premium names
count?", left settable rather than decided here. UNSET, THE CAP COVERS
NOTHING and no credit redeems (re-audit 2026-10-16, H-1): it used to fall
back to the default name price, and the default rises fast. The deploy
sets it explicitly (tools/deploy-gen.sh, CLAIMMAX).

GRANTED BY THE ADMIN, AND NOT TIMELOCKED, deliberately. A credit can only
create a registration of a name nobody holds: it never touches an
existing holder, moves no money, works only inside the claim window and
only under the price cap. A stolen admin key can gift itself cheap names
until it is rotated out — the same order of harm as the free tier, and
far smaller than anything the timelock guards. A 48-hour wait on every
grant would make "register it for them now" impossible.
*/

const (
	keyCredit   = "cr"       // account field: the record above
	keyClaimEnd = "claimend" // global: unix second the claim window closes; unset means closed
	keyClaimMax = "claimmax" // global: highest list price, micro-USD, a credit covers

	maxCreditsPerAddress = 100
	maxGrantBatch        = 100
	maxClaimWindowDays   = 730 // one setting cannot promise more than two years
)

type credit struct {
	granted, used, expires int64
	held                   bool
	at                     int64 // when granted; 0 for a record from before the field
}

// parseCredit FAILS CLOSED: anything it cannot read is no credit at all.
// A malformed record must never be read as a free name. Four fields is the
// record before the grant time existed; five carries it.
func parseCredit(v string) credit {
	if v == "" {
		return credit{}
	}
	f := strings.Split(v, ",")
	if (len(f) != 4 && len(f) != 5) || (f[3] != "0" && f[3] != "1") {
		return credit{}
	}
	g, e1 := strconv.ParseInt(f[0], 10, 64)
	u, e2 := strconv.ParseInt(f[1], 10, 64)
	x, e3 := strconv.ParseInt(f[2], 10, 64)
	if e1 != nil || e2 != nil || e3 != nil || g < 0 || u < 0 || x < 0 {
		return credit{}
	}
	c := credit{granted: g, used: u, expires: x, held: f[3] == "1"}
	if len(f) == 5 {
		at, e4 := strconv.ParseInt(f[4], 10, 64)
		if e4 != nil || at < 0 {
			return credit{}
		}
		c.at = at
	}
	return c
}

func (c credit) encode() string {
	h := "0"
	if c.held {
		h = "1"
	}
	return strconv.FormatInt(c.granted, 10) + "," + strconv.FormatInt(c.used, 10) + "," +
		strconv.FormatInt(c.expires, 10) + "," + h + "," + strconv.FormatInt(c.at, 10)
}

// voided reports whether recovery voided the time this credit was granted.
func (c credit) voided() bool { return c.granted > c.used && nsdata.GrantVoided(c.at) }

// available is how many may be redeemed at `now`.
func (c credit) available(now int64) int64 {
	if c.expires != 0 && now >= c.expires {
		return 0
	}
	if c.used >= c.granted {
		return 0
	}
	return c.granted - c.used
}

func readCredit(owner address) credit { return parseCredit(nsdata.GetAccount(owner, keyCredit)) }

func writeCredit(cur realm, owner address, c credit) {
	v := c.encode()
	// Nothing granted and nothing used is no record: free the storage.
	// A record with redemptions stays, because `used` is what stops a
	// repeated grant from handing out a second name.
	if c.granted == 0 && c.used == 0 {
		v = ""
	}
	if err := nsdata.SetAccountRecord(cross(cur), owner, keyCredit, v); err != nil {
		panic("nslogic: " + err.Error())
	}
}

// CreditsOf reports an address's credits: how many it may redeem right
// now, and the record behind that answer. `sellable` is whether the names
// they buy come without the free-tier hold — true unless the grant said not.
// Credits recovery voided are not available; the window, a pause and a
// quarantine are the registry's state, reported by CreditRefusal.
func CreditsOf(owner address) (available, granted, used, expires int64, sellable bool) {
	c := readCredit(owner)
	a := c.available(time.Now().Unix())
	if c.voided() {
		a = 0
	}
	return a, c.granted, c.used, c.expires, !c.held
}

// CreditGrantedAt is when an address's credits were last granted (unix
// seconds; 0 for none, or for a record from before the field existed).
func CreditGrantedAt(owner address) int64 { return readCredit(owner).at }

// -- the window and the cap --

// ClaimWindowEnd is the unix second redemption closes, or 0 when no
// window is set — which means CLOSED. An entitlement nobody bounded is a
// liability that never ends, so the default is no window at all.
func ClaimWindowEnd() int64 {
	v := nsdata.GetGlobal(keyClaimEnd)
	if v == "" {
		return 0
	}
	end, err := strconv.ParseInt(v, 10, 64)
	if err != nil || end < 0 {
		return 0
	}
	return end
}

func ClaimWindowOpen() bool { return readClaimWindow(nsdata.GetGlobal(keyClaimEnd), time.Now().Unix()) }

// readClaimWindow fails closed on anything it cannot read, the same rule
// the free tier's window follows: a mistyped setting must not give names away.
func readClaimWindow(v string, now int64) bool {
	if v == "" {
		return false
	}
	end, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return false
	}
	return now < end
}

// SetClaimWindow opens redemption until `end` (unix seconds), at most two
// years ahead, or closes it with 0. Closing is the one call to reach for
// on a Sunday when something about the grants looks wrong.
func SetClaimWindow(cur realm, end int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetClaimWindow", "end", fmtInt(end))
	if end == 0 {
		setGlobal(cur, keyClaimEnd, "")
		return
	}
	now := time.Now().Unix()
	if end <= now || end > now+maxClaimWindowDays*86400 {
		panic("nslogic: a claim window ends in the future and at most " +
			strconv.Itoa(maxClaimWindowDays) + " days ahead; 0 closes it")
	}
	setGlobal(cur, keyClaimEnd, strconv.FormatInt(end, 10))
}

/*
ClaimMaxPriceUSD is the highest list price, in micro-USD, a credit can be
spent on, or 0 while no cap is set — and while none is set no credit
redeems at all (ClaimCapSet).

IT NEVER FOLLOWS THE DEFAULT PRICE (re-audit 2026-10-16, H-1). It used to
fall back to DefaultPriceUSD while unset, which is how a registry is born.
The default moves fast in its "dearer" direction — four times, every ten
minutes, instantly — and premium prices do not move with it, so each
dearer step on the default carried the cap past another tier of premium
names: a stolen admin key took the $300 x*doge with a free credit in forty
minutes, never touching SetClaimMaxPrice, whose raise is meant to be the
slow step. So the cap stands on its own now, an unset or unreadable one
covers nothing, and the first cap is a decision (SetClaimMaxPrice).
*/
func ClaimMaxPriceUSD() int64 {
	p, _ := claimCap()
	return p
}

// ClaimCapSet reports whether a cap is set at all. Unset — or unreadable,
// which is read the same way — no credit can be spent on anything.
func ClaimCapSet() bool {
	_, ok := claimCap()
	return ok
}

func claimCap() (int64, bool) {
	v := nsdata.GetGlobal(keyClaimMax)
	if v == "" {
		return 0, false
	}
	p, err := strconv.ParseInt(v, 10, 64)
	if err != nil || p < 0 {
		return 0, false
	}
	return p, true
}

// SetClaimMaxPrice is BOUNDED like a price (timelock.gno), with the
// direction turned round: RAISING the cap is what makes names cheaper — a
// credit then covers pricier names, premium ones in the end — so a raise is
// the slow step (25%, once an hour) and a cut the fast one (down to a
// quarter, every ten minutes). Anything else is a timelocked proposal.
//
// THE FIRST CAP IS NOT A STEP. From no cap there is nothing to step from,
// so setting one is always the timelocked proposal: instant at a fresh
// vault's delay of zero, which is when the deploy sets it, and recovery's
// to veto once the delay is raised.
func SetClaimMaxPrice(cur realm, microUsd int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetClaimMaxPrice", "microUsd", fmtInt(microUsd))
	if microUsd < 0 || microUsd > maxPriceUSD {
		panic("nslogic: the claim cap must be 0.." + strconv.FormatInt(maxPriceUSD, 10) + " micro-USD")
	}
	v := strconv.FormatInt(microUsd, 10)
	id := actionID("SetClaimMaxPrice", v)
	old, set := claimCap()
	if !set {
		requireAction(cur, id)
		// A cap from nothing is the cheaper direction for claimants: the
		// next raise waits the cheap clock's hour like any other.
		lastTweak.Set(clockKey(keyClaimMax, false), time.Now().Unix())
	} else {
		authorizeTweak(cur, keyClaimMax, old, microUsd, microUsd < old, id)
	}
	setGlobal(cur, keyClaimMax, v)
}

// -- granting --

// GrantCredits SETS how many free registrations `to` is entitled to in
// total, with an optional expiry (0 for none) and whether the names they
// buy are SELLABLE — true is the default to pass; false mints them with
// the free-tier hold. 0 revokes whatever is unredeemed. See the note at
// the top of this file on why a grant sets rather than adds.
func GrantCredits(cur realm, to address, n, expires int64, sellable bool) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "GrantCredits", "to", to.String(), "n", fmtInt(n), "expires", fmtInt(expires), "sellable", fmtBool(sellable))
	grantCredits(cur, to, n, expires, sellable, time.Now().Unix())
}

// GrantCreditsBatch is GrantCredits for a comma-separated list of
// addresses, up to 100 a call — the migration grant is one entry per
// testnet wallet. Returns how many were written. One bad address fails
// the whole batch, so a typo cannot silently leave somebody out.
func GrantCreditsBatch(cur realm, addrs string, n, expires int64, sellable bool) int {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "GrantCreditsBatch", "addrs", addrs, "n", fmtInt(n), "expires", fmtInt(expires), "sellable", fmtBool(sellable))
	parts := strings.Split(addrs, ",")
	if len(parts) > maxGrantBatch {
		panic("nslogic: at most " + strconv.Itoa(maxGrantBatch) + " addresses per batch")
	}
	now := time.Now().Unix()
	done := 0
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		grantCredits(cur, address(p), n, expires, sellable, now)
		done++
	}
	return done
}

func grantCredits(cur realm, to address, n, expires int64, sellable bool, now int64) {
	if !to.IsValid() {
		panic("nslogic: not an address: " + to.String())
	}
	if n < 0 || n > maxCreditsPerAddress {
		panic("nslogic: a grant is 0.." + strconv.Itoa(maxCreditsPerAddress) + " credits")
	}
	if expires != 0 && expires <= now {
		panic("nslogic: credits that have already expired are not a grant; pass 0 for no expiry")
	}
	c := readCredit(to)
	c.granted, c.expires, c.held, c.at = n, expires, !sellable, now
	writeCredit(cur, to, c)
}

// -- redeeming --

// RedeemCredit registers label*domain to the caller and spends one of the
// caller's credits. The caller signs, so the caller pays the storage
// deposit and gas; the name itself costs nothing.
func RedeemCredit(cur realm, label, domainLabel string) {
	assertNoSend(cur)
	redeemCredit(cur, cur.Previous().Address(), label, domainLabel)
}

// RegisterFor registers label*domain to `owner` and spends one of
// OWNER'S credits — the project signs and pays the storage and gas, which
// is the only way a holder with no GNOT can get a name at all. Admin or
// granter: the same machine that issues free names relays these, and it
// can spend only credits the admin granted, only into the holder's own
// wallet.
func RegisterFor(cur realm, owner address, label, domainLabel string) {
	assertNoSend(cur)
	assertMayGrant(cur)
	emitAdmin(cur, "RegisterFor", "owner", owner.String(), "label", label, "domain", domainLabel)
	if !owner.IsValid() {
		panic("nslogic: a registration needs a recipient")
	}
	redeemCredit(cur, owner, label, domainLabel)
}

// CreditRefusal is why `owner` could not spend a credit on label*domain
// right now, or "" when nothing about the credit stands in the way. For
// the site, before anybody signs; the label rules are checked separately.
func CreditRefusal(owner address, label, domainLabel string) string {
	return creditRefusal(owner, label, domainLabel, time.Now().Unix())
}

func creditRefusal(owner address, label, domainLabel string, now int64) string {
	if nsdata.IsPaused() {
		return "the registry is paused"
	}
	if q := nsdata.QuarantineUntil(); now < q {
		return "recovery has quarantined giveaways until unix " + strconv.FormatInt(q, 10)
	}
	if !readClaimWindow(nsdata.GetGlobal(keyClaimEnd), now) {
		return "the claim window is closed"
	}
	c := readCredit(owner)
	if c.available(now) <= 0 {
		if c.granted > c.used && c.expires != 0 && now >= c.expires {
			return "this address's credits have expired"
		}
		return "this address has no credit to spend"
	}
	if c.voided() {
		return "recovery voided the credits granted to this address at unix " + strconv.FormatInt(c.at, 10) +
			"; the admin may grant them again"
	}
	most, set := claimCap()
	if !set {
		return "credits are off: no claim cap is set, and an unset cap covers nothing"
	}
	if p := NamePriceUSD(domainLabel, label); p > most {
		return "a credit covers names listed at up to " + strconv.FormatInt(most, 10) +
			" micro-USD, and this one lists at " + strconv.FormatInt(p, 10)
	}
	return ""
}

/*
redeemCredit is both doors. Every check runs before anything is written,
the registration lands before the credit is spent, and either failing
reverts the other: the credit cannot be spent on a name that did not
arrive, and a name cannot arrive without its credit being spent.
*/
func redeemCredit(cur realm, owner address, label, domainLabel string) {
	assertNotRestoring()
	validateLabel(label)
	assertNotBlocked(label)
	if !DomainOpen(domainLabel) {
		panic("nslogic: this domain is not accepting new names")
	}
	now := time.Now().Unix()
	if r := creditRefusal(owner, label, domainLabel, now); r != "" {
		panic("nslogic: " + r)
	}
	c := readCredit(owner)
	if err := nsdata.RegisterNameRecord(cross(cur), label, domainLabel, owner, now, !c.held); err != nil {
		panic(err)
	}
	c.used++
	writeCredit(cur, owner, c)
	chain.Emit("CreditRedeemed", "tid", label+"*"+domainLabel, "owner", owner.String(),
		"by", cur.Previous().Address().String())
}
