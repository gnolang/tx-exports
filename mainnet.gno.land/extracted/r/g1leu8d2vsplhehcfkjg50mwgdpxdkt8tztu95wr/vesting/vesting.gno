// Package vesting holds grants of GNOT, BUBBLE or any registered GRC20 and pays each out on its own schedule:
// a share at the start, the rest by the day over a term, to one beneficiary, for as long as the grant's owner
// does not revoke it. Anyone may open a grant for anyone; nothing here is a setting but each grant's owner.
//
// Every grant has its OWN address — the realm's sub-realm `grant-<id>` (chain.DerivePkgSubAddr) — and that is how
// it is funded: send the tokens there (a bank send for GNOT, Transfer for a GRC20, a holders' vote that mints
// BUBBLE to it). The realm moves tokens out of a grant's address and never between grants; what sits at the
// realm's main address belongs to nobody and stays there, so send only to a grant's address.
//
// The schedule. Nothing before start, or before start + cliff; at start the up-front share is vested; each full
// day after start vests an equal share of the rest, until day Days, when all of Total has vested (Days 0: all of
// it at start). Claim pays the beneficiary what has vested and not yet been paid, as far as the grant's balance
// goes; anyone may call it, since the money has one destination. Revoke, by the owner, freezes the schedule where
// it stands and returns everything above what has vested to the owner; what had vested stays the beneficiary's to
// claim. A revoke before the up-front share has arrived (what was already paid counts as arrived) VOIDS the grant:
// nothing vests, and whatever lands later is the owner's to sweep. Sweep, by the owner, returns what the schedule can never owe (a gift,
// a double funding) without ending anything. A grant opened with no owner is irrevocable, and its excess is the
// beneficiary's to sweep.
//
// Votes. BUBBLE held by a grant is self-delegated, inside the token's ledger, to the grant's own address, and this
// realm never delegates it or votes with it; the beneficiary's weight grows as they claim.
//
// Immutable, not private (gnomod.toml).
package vesting

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	pkgPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/vesting" // must match gnomod.toml
	day     = int64(86400)

	// GNOT and BUBBLE are the two tokens named directly; every other token is a registry key
	// (gno.land/r/nt/grc20reg/v0) such as gno.land/r/g1leu8d2…95wr/wbubble.BUBBLE.
	GNOT   = "ugnot"
	BUBBLE = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble"

	MaxDays = int64(36500) // a term, and a cliff, of at most a hundred years: the arithmetic below counts on it
	maxNote = 120
	listMax = 50 // grants the front page lists
)

type kind int

const (
	kindNative kind = iota
	kindBubble
	kindRegistry
)

// Grant is one schedule. The fields are read through Get; only this realm writes them.
type Grant struct {
	ID          int64
	Token       string  // GNOT, BUBBLE or a registry key
	Creator     address // who opened it (named on the page: an owner is named, not implied to have opened it)
	Owner       address // may revoke and sweep; "" for an irrevocable grant
	OwnerNext   address // named by the owner, taken by the named: the two-step hand-off
	Beneficiary address
	Total       int64 // base units
	Upfront     int64 // vested at start
	Start       int64 // unix time the schedule counts from
	CliffDays   int64 // nothing is claimable before Start + CliffDays
	Days        int64 // the rest vests by the day over this many days after Start
	Claimed     int64 // paid to the beneficiary
	Returned    int64 // sent back to the owner
	RevokedAt   int64 // 0 while the grant runs
	Voided      bool  // revoked before anything arrived or was paid: nothing vests
	Note        string
}

var (
	grants = avl.NewTree() // key(id) → *Grant
	last   int64
)

// init refuses a deploy at a path other than pkgPath: Address() would then name sub-addresses nothing controls.
func init(cur realm) {
	if cur.Address() != chain.PackageAddress(pkgPath) {
		panic("vesting: deployed at a path other than pkgPath")
	}
}

// ---------------------------------------------------------------- reading --

func Count() int64 { return last }

// Get is a copy of the grant.
func Get(id int64) Grant { return *get(id) }

// Address is where a grant is funded: the realm's sub-realm for it. Only for a grant that exists.
func Address(id int64) address {
	get(id)
	return chain.DerivePkgSubAddr(pkgPath, subpath(id))
}

// Balance is what the grant's address holds of its token.
func Balance(id int64) int64 { return balance(get(id)) }

// Vested is what the schedule has released by now — or by the revoke, if there was one. Never above Total.
func Vested(id int64) int64 { return vested(get(id)) }

// Claimable is what Claim would pay now: the vested part not yet paid, as far as the balance goes.
func Claimable(id int64) int64 { return claimable(get(id)) }

func subpath(id int64) string { return "grant-" + strconv.FormatInt(id, 10) }

func key(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func get(id int64) *Grant {
	if id <= 0 || id > last {
		panic("vesting: no grant " + strconv.FormatInt(id, 10))
	}
	return grants.Get(key(id)).(*Grant)
}

func balance(g *Grant) int64 {
	addr := chain.DerivePkgSubAddr(pkgPath, subpath(g.ID))
	switch kindOf(g.Token) {
	case kindNative:
		return banker.NewReadonlyBanker().GetCoin(addr, GNOT) // one denom read: dust in other denoms cannot bloat it
	case kindBubble:
		return bubble.BalanceOf(addr)
	}
	return grc20reg.MustGet(g.Token).BalanceOf(addr)
}

func vested(g *Grant) int64 {
	if g.Voided {
		return 0
	}
	t := time.Now().Unix()
	if g.RevokedAt != 0 {
		t = g.RevokedAt
	}
	return vestedAt(g, t)
}

// vestedAt is the schedule itself. The split of rest*d/Days into a quotient and a remainder part keeps every
// intermediate inside int64 for any Total and a term under MaxDays, and equals the exact floor.
func vestedAt(g *Grant, t int64) int64 {
	if t < g.Start || t < g.Start+g.CliffDays*day {
		return 0
	}
	d := (t - g.Start) / day
	if g.Days == 0 || d >= g.Days {
		return g.Total
	}
	rest := g.Total - g.Upfront
	return g.Upfront + (rest/g.Days)*d + (rest%g.Days)*d/g.Days
}

func claimable(g *Grant) int64 {
	due := vested(g) - g.Claimed
	if bal := balance(g); due > bal {
		due = bal
	}
	if due < 0 {
		return 0
	}
	return due
}

func kindOf(token string) kind {
	switch token {
	case GNOT:
		return kindNative
	case BUBBLE:
		return kindBubble
	}
	return kindRegistry
}

// canon names the token as the realm stores it: GNOT and BUBBLE by their constants, anything else by its registry
// key, which must resolve.
func canon(token string) string {
	switch strings.ToLower(token) {
	case "gnot", "ugnot":
		return GNOT
	case "bubble", BUBBLE:
		return BUBBLE
	}
	if grc20reg.Get(token) == nil {
		panic("vesting: unknown token " + token + ": say gnot, bubble, or a key of gno.land/r/nt/grc20reg/v0")
	}
	return token
}

// ---------------------------------------------------------------- writing --

func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("vesting: spoofed realm")
	}
	return cur.Previous().Address()
}

func mustBeOwner(cur realm, g *Grant) {
	if g.Owner == "" {
		panic("vesting: this grant has no owner; it cannot be revoked or handed on")
	}
	if caller(cur) != g.Owner {
		panic("vesting: only the grant's owner")
	}
}

// Create opens a grant and returns its id. owner may revoke it ("" makes it irrevocable); the tokens are sent to
// Address(id) afterwards, by anyone. token: "gnot", "bubble" or a registry key. start 0 is now; a past start is
// allowed, a future one up to a hundred years out. days 0 vests everything at start. note is a label of up to 120
// plain characters (no markup: the pages render it).
func Create(cur realm, owner, beneficiary address, token string, total, upfront, start, cliffDays, days int64, note string) int64 {
	creator := caller(cur)
	if !beneficiary.IsValid() {
		panic("vesting: the beneficiary is not an address")
	}
	if owner != "" && !owner.IsValid() {
		panic("vesting: the owner is not an address")
	}
	if owner == beneficiary {
		panic("vesting: the owner cannot be the beneficiary")
	}
	if total <= 0 {
		panic("vesting: the total must be positive")
	}
	if upfront < 0 || upfront > total {
		panic("vesting: the up-front share is between 0 and the total")
	}
	if days < 0 || days > MaxDays || cliffDays < 0 || cliffDays > MaxDays {
		panic("vesting: days and cliffDays are between 0 and " + strconv.FormatInt(MaxDays, 10))
	}
	now := time.Now().Unix()
	if start < 0 || start > now+MaxDays*day {
		panic("vesting: start is a unix time within a hundred years, or 0 for now")
	}
	if start == 0 {
		start = now
	}
	if next := chain.DerivePkgSubAddr(pkgPath, subpath(last+1)); beneficiary == next || owner == next {
		panic("vesting: a grant cannot pay its own address")
	}
	if len(note) > maxNote {
		panic("vesting: the note is at most " + strconv.Itoa(maxNote) + " characters")
	}
	for i := 0; i < len(note); i++ {
		if note[i] < 0x20 || note[i] == 0x7f || strings.IndexByte("[]()<>`*_#|\\", note[i]) >= 0 {
			panic("vesting: the note is plain text without markup")
		}
	}
	token = canon(token)
	last++
	g := &Grant{ID: last, Token: token, Creator: creator, Owner: owner, Beneficiary: beneficiary, Total: total, Upfront: upfront, Start: start, CliffDays: cliffDays, Days: days, Note: note}
	grants.Set(key(last), g)
	chain.Emit("Grant", "id", strconv.FormatInt(last, 10), "token", token, "to", beneficiary.String(), "owner", owner.String(), "by", creator.String(), "total", strconv.FormatInt(total, 10), "address", Address(last).String())
	return last
}

// Claim pays the beneficiary everything claimable and returns the amount. Anyone may call it.
func Claim(cur realm, id int64) int64 {
	caller(cur)
	g := get(id)
	n := claimable(g)
	if n <= 0 {
		if vested(g) > g.Claimed {
			panic("vesting: nothing here to pay yet; the grant's address holds less than is due")
		}
		panic("vesting: nothing to claim")
	}
	g.Claimed += n
	send(cur, g, g.Beneficiary, n)
	chain.Emit("Claim", "id", strconv.FormatInt(id, 10), "to", g.Beneficiary.String(), "amount", strconv.FormatInt(n, 10))
	return n
}

// Revoke ends the schedule where it stands (the first time) and returns to the owner everything the grant holds
// beyond what has vested and is still the beneficiary's to claim. Before the up-front share has arrived, counting
// what was already paid out as arrived, it voids the grant instead: nothing vests, ever — so a unit of dust sent
// ahead of the owner's revoke, claimed or not, cannot turn a void into a freeze that keeps the up-front share. (A
// grant with no up-front share measures against what the schedule had released by the revoke.) Returns what went
// back; 0 when nothing did.
func Revoke(cur realm, id int64) int64 {
	g := get(id)
	mustBeOwner(cur, g)
	if g.RevokedAt == 0 {
		g.RevokedAt = time.Now().Unix()
		floor := g.Upfront
		if floor == 0 {
			floor = vestedAt(g, g.RevokedAt)
		}
		if floor == 0 {
			floor = 1
		}
		g.Voided = g.Claimed+balance(g) < floor
		chain.Emit("Revoked", "id", strconv.FormatInt(id, 10), "at", strconv.FormatInt(g.RevokedAt, 10), "voided", strconv.FormatBool(g.Voided))
	}
	return sweep(cur, g)
}

// Sweep returns to the owner what the schedule can never owe the beneficiary — above the unpaid rest of the grant
// while it runs, above what is still claimable once revoked — without ending anything. Owner only; on a grant with
// no owner the excess is the beneficiary's, and anyone may send it there.
func Sweep(cur realm, id int64) int64 {
	g := get(id)
	if g.Owner == "" {
		caller(cur)
		return sweepTo(cur, g, g.Beneficiary)
	}
	mustBeOwner(cur, g)
	return sweep(cur, g)
}

func sweep(cur realm, g *Grant) int64 { return sweepTo(cur, g, g.Owner) }

func sweepTo(cur realm, g *Grant, to address) int64 {
	owed := g.Total - g.Claimed
	if g.RevokedAt != 0 {
		owed = claimable(g)
	}
	back := balance(g) - owed
	if back <= 0 {
		return 0
	}
	g.Returned += back
	send(cur, g, to, back)
	chain.Emit("Returned", "id", strconv.FormatInt(g.ID, 10), "to", to.String(), "amount", strconv.FormatInt(back, 10))
	return back
}

// send moves n of the grant's token out of the grant's own address: the sub-realm is the sender, so one grant can
// never pay from another's balance.
func send(cur realm, g *Grant, to address, n int64) {
	sub := cur.Sub(subpath(g.ID))
	switch kindOf(g.Token) {
	case kindNative:
		banker.NewBanker(banker.BankerTypeRealmSend, sub).SendCoins(sub.Address(), to, chain.Coins{{GNOT, n}})
	case kindBubble:
		bubble.Transfer(cross(sub), to, n)
	default:
		tok := grc20reg.MustGet(g.Token)
		if err := tok.RealmTeller(0, sub).Transfer(0, sub, to, n); err != nil {
			panic("vesting: " + err.Error())
		}
	}
}

// SetOwner names the next owner; nothing moves until they AcceptOwner. Naming "" withdraws the offer.
func SetOwner(cur realm, id int64, to address) {
	g := get(id)
	mustBeOwner(cur, g)
	if to != "" && !to.IsValid() {
		panic("vesting: not an address")
	}
	if to == g.Beneficiary {
		panic("vesting: the owner cannot be the beneficiary")
	}
	g.OwnerNext = to
	chain.Emit("OwnerNext", "id", strconv.FormatInt(id, 10), "to", to.String())
}

// AcceptOwner takes the owner role of a grant, by the one named.
func AcceptOwner(cur realm, id int64) {
	g := get(id)
	who := caller(cur)
	if g.OwnerNext == "" || who != g.OwnerNext {
		panic("vesting: not the named next owner")
	}
	g.Owner, g.OwnerNext = who, ""
	chain.Emit("Owner", "id", strconv.FormatInt(id, 10), "to", who.String())
}

// ----------------------------------------------------------------- pages --

// Render: "" the newest grants; "<id>" one grant; "json/<id>" its figures in base units; "by/<address>" the grants
// an address owns or receives.
func Render(path string) string {
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return home()
	case len(parts) == 1:
		id, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil || id <= 0 || id > last {
			return "404"
		}
		return page(get(id))
	case len(parts) == 2 && parts[0] == "json":
		id, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || id <= 0 || id > last {
			return "404"
		}
		return json(get(id))
	case len(parts) == 2 && parts[0] == "by":
		return by(address(parts[1]))
	}
	return "404"
}

func home() string {
	var b strings.Builder
	b.WriteString("# Vesting grants\n\n")
	b.WriteString(strconv.FormatInt(last, 10) + " grants. Anyone opens one with Create (owner, beneficiary, token, total, up-front share, start, cliff days, days, a note) and funds it by sending the token to the grant's own address; Claim pays the beneficiary what has vested; the owner alone can revoke. Tokens: GNOT, BUBBLE, or any key of the GRC20 registry.\n\n")
	n := 0
	grants.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*Grant)
		b.WriteString("- [#" + strconv.FormatInt(g.ID, 10) + "](" + pkgPath + ":" + strconv.FormatInt(g.ID, 10) + ") " + amount(g, g.Total) + " to " + g.Beneficiary.String() + " · " + state(g))
		if g.Note != "" {
			b.WriteString(" · " + g.Note)
		}
		b.WriteString("\n")
		n++
		return n >= listMax
	})
	return b.String()
}

func page(g *Grant) string {
	var b strings.Builder
	b.WriteString("# Grant #" + strconv.FormatInt(g.ID, 10))
	if g.Note != "" {
		b.WriteString(": " + g.Note)
	}
	b.WriteString("\n\n")
	b.WriteString("- to: " + g.Beneficiary.String() + "\n")
	b.WriteString("- grant: " + amount(g, g.Total) + " — " + amount(g, g.Upfront) + " at the start")
	if g.Days > 0 {
		b.WriteString(", the rest by the day over " + strconv.FormatInt(g.Days, 10) + " days")
	}
	b.WriteString(" from " + date(g.Start))
	if g.CliffDays > 0 {
		b.WriteString("; nothing before " + date(g.Start+g.CliffDays*day) + " (a cliff of " + strconv.FormatInt(g.CliffDays, 10) + " days)")
	}
	b.WriteString("\n")
	b.WriteString("- vested: " + amount(g, vested(g)) + " · paid: " + amount(g, g.Claimed) + " · claimable now: " + amount(g, claimable(g)) + " · held at the grant's address: " + amount(g, balance(g)) + "\n")
	b.WriteString("- state: " + state(g))
	switch {
	case g.Voided:
		b.WriteString(" — revoked on " + date(g.RevokedAt) + " before anything arrived; nothing vests; " + amount(g, g.Returned) + " went back to the owner")
	case g.RevokedAt != 0:
		b.WriteString(" — revoked on " + date(g.RevokedAt) + "; the schedule stopped there; " + amount(g, g.Returned) + " went back to the owner")
	case g.Owner == "":
		b.WriteString(" — irrevocable: nobody can end it; anything beyond the grant is the beneficiary's (Sweep)")
	default:
		b.WriteString(" — the owner can revoke; what has vested by then stays the beneficiary's")
	}
	b.WriteString("\n")
	if g.Owner != "" {
		b.WriteString("- owner: " + g.Owner.String())
		if g.OwnerNext != "" {
			b.WriteString(" (hand-off offered to " + g.OwnerNext.String() + ")")
		}
		b.WriteString("\n")
	}
	b.WriteString("- opened by: " + g.Creator.String() + "\n")
	b.WriteString("- token: " + g.Token + "\n")
	b.WriteString("- the grant's address, to fund it: " + chain.DerivePkgSubAddr(pkgPath, subpath(g.ID)).String() + "\n\n")
	b.WriteString("Claim pays the beneficiary what has vested and not been paid; anyone may call it. A token held here carries no vote until it is claimed.\n")
	return b.String()
}

func by(who address) string {
	if !who.IsValid() { // the path is anyone's text: only an address is echoed onto the page
		return "404"
	}
	var b strings.Builder
	b.WriteString("# Grants of " + who.String() + "\n\n")
	n := 0
	grants.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*Grant)
		if g.Owner != who && g.Beneficiary != who {
			return false
		}
		role := "receives"
		if g.Owner == who {
			role = "owns"
		}
		b.WriteString("- " + role + " [#" + strconv.FormatInt(g.ID, 10) + "](" + pkgPath + ":" + strconv.FormatInt(g.ID, 10) + ") " + amount(g, g.Total) + " · " + state(g) + "\n")
		n++
		return n >= listMax
	})
	if n == 0 {
		b.WriteString("none\n")
	}
	return b.String()
}

func json(g *Grant) string {
	return `{"id":` + strconv.FormatInt(g.ID, 10) + `,"token":"` + g.Token + `","beneficiary":"` + g.Beneficiary.String() + `","owner":"` + g.Owner.String() + `","ownerNext":"` + g.OwnerNext.String() + `","creator":"` + g.Creator.String() +
		`","address":"` + chain.DerivePkgSubAddr(pkgPath, subpath(g.ID)).String() + `","total":` + strconv.FormatInt(g.Total, 10) + `,"upfront":` + strconv.FormatInt(g.Upfront, 10) +
		`,"start":` + strconv.FormatInt(g.Start, 10) + `,"cliffDays":` + strconv.FormatInt(g.CliffDays, 10) + `,"days":` + strconv.FormatInt(g.Days, 10) +
		`,"vested":` + strconv.FormatInt(vested(g), 10) + `,"claimed":` + strconv.FormatInt(g.Claimed, 10) + `,"claimable":` + strconv.FormatInt(claimable(g), 10) + `,"balance":` + strconv.FormatInt(balance(g), 10) +
		`,"revokedAt":` + strconv.FormatInt(g.RevokedAt, 10) + `,"voided":` + strconv.FormatBool(g.Voided) + `,"returned":` + strconv.FormatInt(g.Returned, 10) + `,"note":"` + strings.ReplaceAll(g.Note, `"`, `\"`) + `"}`
}

func state(g *Grant) string {
	switch {
	case g.Voided:
		return "voided"
	case g.RevokedAt != 0:
		return "revoked"
	case g.Claimed >= g.Total:
		return "paid in full"
	case time.Now().Unix() < g.Start:
		return "not started"
	}
	return "running"
}

func date(unix int64) string { return time.Unix(unix, 0).UTC().Format("2006-01-02") }

// amount prints base units in the token's own unit, trailing zeros dropped.
func amount(g *Grant, n int64) string {
	decimals, symbol := 6, "GNOT"
	switch kindOf(g.Token) {
	case kindBubble:
		symbol = "BUBBLE"
	case kindRegistry:
		tok := grc20reg.MustGet(g.Token)
		decimals, symbol = tok.GetDecimals(), tok.GetSymbol()
	}
	one := int64(1)
	for i := 0; i < decimals; i++ {
		one *= 10
	}
	whole, frac := n/one, n%one
	s := strconv.FormatInt(whole, 10)
	if frac != 0 {
		f := strconv.FormatInt(frac, 10)
		for len(f) < decimals {
			f = "0" + f
		}
		s += "." + strings.TrimRight(f, "0")
	}
	return s + " " + symbol
}
