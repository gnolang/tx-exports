package nslogic

import (
	"strconv"
	"strings"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// The referral programme.
//
// SINGLE LEVEL, ALWAYS. One buyer, one referrer, one cut, taken out of
// an actual sale. There is no downline, no override on somebody else's
// referrals, and no bonus for recruiting other referrers — and there is
// no code here that could be extended into one without being obvious
// about it. That is the line between an affiliate programme and the
// other thing, and this realm stays on the near side of it.
//
// WHERE THE LINK LIVES. The referrer is recorded on the REFERRED NAME,
// in its extension slot, at the moment it is registered. That placement
// does the work of two rules for free, because nsdata already destroys a
// name's extras when a lapsed name is re-registered (names.Remove, then
// a fresh record) and when a name changes hands (wipeOnHandover):
//
//	a name that lapses loses its referrer
//	a name that is sold loses its referrer
//
// Neither needs code to enforce. Both would need code to PREVENT.
//
// WHO GETS PAID. An address, not a name. The referrer's wallet is fixed
// into the referred name at registration, so they may let their own name
// go, buy a different one, or hold ten — the commission does not move.
// What they cannot do is leave: paying out requires the referrer to
// still hold at least one name, checked at payment time.
//
// A SKIPPED PAYOUT IS NOT A DEBT. If the referrer holds nothing when a
// renewal comes through, the cut is simply not taken — the buyer pays
// less and the treasury keeps the difference. Nothing accrues, because
// accruing would mean holding somebody else's money until they qualify,
// and this realm holds nobody's money at any point.
//
// SELF-REFERRAL IS REFUSED. Otherwise the informed apply their own code
// forever and the cut becomes a silent discount for people who read the
// source.
//
// EVERYTHING SETTLES IN ONE TRANSACTION. Buyer pays, treasury is paid,
// referrer is paid, overpayment goes back — all inside the message the
// buyer signed. No escrow, no float, not for a block.
const (
	keyRef     = "ref"     // on a NAME: the referrer's address
	keyRefCut  = "refcut"  // global: tier table, referrer's percentage
	keyRefDisc = "refdisc" // global: tier table, buyer's discount
	keyRefStat = "ref:"    // global, per address: how many referred
	keyRefWin  = "refwin"  // global: days a captured code stays valid

	maxRefPercent = 50 // a cut plus a discount above this stops being a business
)

// -- tier tables --

// A tier table reads like the length rules do: "0:5,2:8,5:12" means five
// percent from the start, eight once the referrer has held a name two
// years, twelve at five. The highest tier at or below their tenure wins,
// so gaps are fine and the table never has to be exhaustive. An empty
// table means the programme pays nothing, which is also how it is
// switched off.
func tierPercent(spec string, years int64) int64 {
	best := int64(0)
	for _, part := range strings.Split(spec, ",") {
		kv := strings.SplitN(strings.TrimSpace(part), ":", 2)
		if len(kv) != 2 {
			continue
		}
		at, err1 := strconv.ParseInt(strings.TrimSpace(kv[0]), 10, 64)
		pct, err2 := strconv.ParseInt(strings.TrimSpace(kv[1]), 10, 64)
		if err1 != nil || err2 != nil || at < 0 || pct < 0 {
			continue
		}
		if pct > maxRefPercent {
			pct = maxRefPercent
		}
		if years >= at && pct > best {
			best = pct
		}
	}
	return best
}

func RefCutRules() string      { return nsdata.GetGlobal(keyRefCut) }
func RefDiscountRules() string { return nsdata.GetGlobal(keyRefDisc) }

// RefWindowDays is how long a clicked link keeps counting for. It is
// enforced by the browser that captured the code, not by this realm —
// the chain never sees the click, only the registration that quotes a
// code — so it is stored here purely to be ONE number rather than a
// constant baked separately into the site, the FAQ and the rules page.
// Zero means the default; the site treats an absent value the same way.
func RefWindowDays() int64 {
	d := parseInt64(nsdata.GetGlobal(keyRefWin))
	if d <= 0 {
		return 30
	}
	return d
}

func SetReferralWindow(cur realm, days int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if days < 0 || days > 3650 {
		panic("nslogic: window must be 0-3650 days")
	}
	setGlobal(cur, keyRefWin, strconv.FormatInt(days, 10))
}

// ReferralQuote is what a code is worth, answered before anybody signs
// anything. One call rather than four, because the site needs all of it
// at once to show a price and every extra round trip is a moment where
// the number on screen is not the number the chain will charge.
//
// A referrer of "" means the code did not resolve, and the two
// percentages are then both zero.
func ReferralQuote(refName string, buyer address) (referrer address, tenure, discountPct, cutPct int64) {
	ref := resolveReferrer(refName, buyer)
	if ref == "" {
		return "", 0, 0, 0
	}
	years := TenureYears(ref)
	cut := int64(0)
	// The cut is zero for a referrer holding nothing, and saying so up
	// front is better than showing a percentage that silently will not
	// be paid when the transaction lands.
	if nsdata.BalanceOf(ref) > 0 {
		cut = tierPercent(RefCutRules(), years)
	}
	return ref, years, tierPercent(RefDiscountRules(), years), cut
}

// SetReferralRules replaces both tier tables at once, because setting one
// without the other is how a cut ends up larger than the margin. Passing
// two empty strings turns the programme off: no discount, no commission,
// and registrations stop writing a referrer at all.
func SetReferralRules(cur realm, cutSpec, discountSpec string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	cut := normalizeTiers(cutSpec)
	disc := normalizeTiers(discountSpec)
	// The two are paid out of the same list price, so their sum is what
	// actually leaves the treasury. Checked at every tenure either table
	// mentions rather than only at tier zero, since the tables need not
	// step at the same points.
	for _, y := range tierYears(cut, disc) {
		if tierPercent(cut, y)+tierPercent(disc, y) > maxRefPercent {
			panic("nslogic: cut plus discount exceeds 50% at year " + strconv.FormatInt(y, 10))
		}
	}
	setGlobal(cur, keyRefCut, cut)
	setGlobal(cur, keyRefDisc, disc)
}

func tierYears(specs ...string) []int64 {
	var out []int64
	seen := map[int64]bool{}
	for _, spec := range specs {
		for _, part := range strings.Split(spec, ",") {
			kv := strings.SplitN(strings.TrimSpace(part), ":", 2)
			if len(kv) != 2 {
				continue
			}
			if y, err := strconv.ParseInt(strings.TrimSpace(kv[0]), 10, 64); err == nil && !seen[y] {
				seen[y] = true
				out = append(out, y)
			}
		}
	}
	if len(out) == 0 {
		out = append(out, 0)
	}
	return out
}

// normalizeTiers rejects a malformed table before it is stored, for the
// same reason normalizeRules does: a bad entry that reaches storage is
// then read silently and wrongly on every sale afterwards.
func normalizeTiers(spec string) string {
	if strings.TrimSpace(spec) == "" {
		return ""
	}
	var out []string
	seen := map[int64]bool{}
	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		kv := strings.SplitN(part, ":", 2)
		if len(kv) != 2 {
			panic("nslogic: bad tier, want years:percent — got " + part)
		}
		y, err := strconv.ParseInt(strings.TrimSpace(kv[0]), 10, 64)
		if err != nil || y < 0 || y > 100 {
			panic("nslogic: tier years must be 0-100 — got " + kv[0])
		}
		p, err := strconv.ParseInt(strings.TrimSpace(kv[1]), 10, 64)
		if err != nil || p < 0 || p > maxRefPercent {
			panic("nslogic: tier percent must be 0-50 — got " + kv[1])
		}
		if seen[y] {
			panic("nslogic: duplicate tier year — " + kv[0])
		}
		seen[y] = true
		out = append(out, strconv.FormatInt(y, 10)+":"+strconv.FormatInt(p, 10))
		if len(out) > 16 {
			panic("nslogic: too many tiers (max 16)")
		}
	}
	return strings.Join(out, ",")
}

// -- tenure --

// TenureYears is how long a wallet counts as having been here, measured
// from its PRIMARY name and nothing else.
//
// The honest alternative — the oldest name the wallet holds — means
// walking the whole registry on every quote, which is a read that gets
// slower every time somebody registers and eventually stops working.
// Primary is one lookup and never gets slower. It is also already the
// wallet's declared identity, it is set automatically at a wallet's first
// registration, and a holder who wants an older name counted only has to
// make it their primary. The site says so on the referral page.
//
// A lapsed or missing primary is zero years, not an error: tier zero.
func TenureYears(who address) int64 {
	tid := nsdata.GetPrimary(who)
	at := strings.Index(tid, "*")
	if at < 1 { // "" or "*domain" — a domain primary has no name streak
		return 0
	}
	label, domainLabel := tid[:at], tid[at+1:]
	if !nsdata.NameExists(label, domainLabel) || !nsdata.IsNameValid(label, domainLabel) {
		return 0
	}
	_, _, _, streak, _, _ := nsdata.GetNameInfo(label, domainLabel)
	return streak
}

// -- where it gets paid --

// Commissions go to the referring wallet. There is no way to redirect
// them, and that is a decision rather than an omission.
//
// There WAS a redirect — SetReferralPayout, "a forwarding address, not a
// transferable right". It does not survive the obvious question: how
// would this realm tell somebody moving money between their own two
// wallets from somebody who has sold the stream to a stranger? It
// cannot. Nothing on chain distinguishes those, and a rule that cannot
// be enforced is not a rule, it is a sentence in a document.
//
// What settled it is that the redirect did not even serve the case it
// was written for. Calling it required signing from the ORIGINAL wallet,
// so "I lost access to my wallet" was never covered; the only wallet
// that could redirect was one whose owner could equally have received
// the money and forwarded it. It gave nothing to the honest case and
// gave the shape of an assignable income stream to the other one.
//
// So the destination is the referrer's own address, fixed. Selling the
// entitlement now means handing over private keys, which is a deterrent
// no contract clause could match.
func PayoutFor(who address) address { return who }

// -- the record on a name --

// ReferrerOf reads the wallet credited with a name, or the empty address.
func ReferrerOf(label, domainLabel string) address {
	v := nsdata.GetNameExtra(label, domainLabel, keyRef)
	if a := address(v); v != "" && a.IsValid() {
		return a
	}
	return ""
}

// resolveReferrer turns a claimed referring NAME into the wallet to
// credit, or the empty address if the claim does not stand up. Every
// rejection is silent on purpose: a mistyped or self-referral should not
// fail somebody's registration, it should simply earn nobody anything.
func resolveReferrer(refName string, buyer address) address {
	at := strings.Index(refName, "*")
	if refName == "" || at < 1 || at == len(refName)-1 {
		return ""
	}
	label, domainLabel := refName[:at], refName[at+1:]
	if !nsdata.NameExists(label, domainLabel) || !nsdata.IsNameValid(label, domainLabel) {
		return "" // a lapsed name is not a working code
	}
	owner := nsdata.GetNameOwner(label, domainLabel)
	if owner == buyer {
		return "" // no referring yourself
	}
	return owner
}

// -- the money --

// PriceWithReferral is what a buyer actually pays given the code they
// arrived with. Exported so the site can display the number the chain
// will charge instead of computing its own and hoping they agree.
func PriceWithReferral(domainLabel, label, refName string, buyer address) int64 {
	price := NamePrice(domainLabel, label)
	if price <= 0 {
		return 0 // free is free, and a percentage of nothing is nothing
	}
	ref := resolveReferrer(refName, buyer)
	if ref == "" {
		return price
	}
	pct := tierPercent(RefDiscountRules(), TenureYears(ref))
	if pct <= 0 {
		return price
	}
	return price - (price * pct / 100)
}

// referralCut is what leaves for the referrer out of a payment of
// `price`, and is zero unless they still hold a name. Returns the
// destination address and the amount; the caller pays it in the same
// banker call that pays the treasury.
func referralCut(ref address, price int64) (address, int64) {
	if ref == "" || price <= 0 {
		return "", 0
	}
	// Still here? A programme that pays people who have left is a
	// standing charge on the project with nothing coming back.
	if nsdata.BalanceOf(ref) <= 0 {
		return "", 0
	}
	pct := tierPercent(RefCutRules(), TenureYears(ref))
	if pct <= 0 {
		return "", 0
	}
	cut := price * pct / 100
	if cut <= 0 {
		return "", 0
	}
	return PayoutFor(ref), cut
}

// -- the scoreboard --

// creditReferral records one paid referral against a wallet.
//
// The COUNT and nothing else. There was a running total of micro-USD
// beside it, and it is gone, because a number stored in the vault is a
// number anyone with an RPC endpoint can read — there is no such thing
// as an admin-only global on a public chain, and building the site as
// though there were would be the kind of privacy that works right up
// until somebody checks.
//
// Not storing it is the only real reduction available. The payments are
// still in the block history and always will be, so anyone determined
// can add them up; what we can decline to do is publish a convenient
// running total ourselves. tools/referrals.py reconstructs it from the
// chain when we want it, which costs no storage and publishes nothing.
//
// The registrant's transaction pays for this entry. It is about forty
// bytes, written once per referrer and overwritten after, and it is the
// price of the discount they just received.
func creditReferral(cur realm, ref address) {
	if ref == "" {
		return
	}
	setGlobal(cur, keyRefStat+ref.String(),
		strconv.FormatInt(ReferralCount(ref)+1, 10))
}

// ReferralCount is how many paid registrations a wallet has been
// credited with. Public, like every other global here.
func ReferralCount(who address) int64 {
	return parseInt64(nsdata.GetGlobal(keyRefStat + who.String()))
}

func parseInt64(s string) int64 {
	v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0
	}
	return v
}

// ReferralBoard pages through every credited wallet for the
// leaderboard: one "address,count" row per line. The vault stores
// globals in a sorted tree, so the "ref:" entries are one contiguous run
// and the walk stops at the first key past it rather than reading the
// rest of the config.
func ReferralBoard(after string, limit int) (rows, next string) {
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	from := keyRefStat
	if after != "" {
		from = keyRefStat + after
	}
	var out []string
	for len(out) < limit {
		keys, more := nsdata.ExportGlobalKeys(from, limit)
		if keys == "" {
			break
		}
		stop := false
		for _, k := range strings.Split(keys, ",") {
			if !strings.HasPrefix(k, keyRefStat) {
				stop = true
				break
			}
			addr := k[len(keyRefStat):]
			n := ReferralCount(address(addr))
			if n <= 0 {
				continue
			}
			out = append(out, addr+","+strconv.FormatInt(n, 10))
			if len(out) >= limit {
				next = addr
				break
			}
		}
		if stop || more == "" || more == from {
			break
		}
		from = more
	}
	return strings.Join(out, "\n"), next
}
