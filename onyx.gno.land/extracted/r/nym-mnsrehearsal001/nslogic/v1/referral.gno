package nslogic

import (
	"strconv"
	"strings"
	"time"

	"gno.land/r/nym-mnsrehearsal001/nsdata/v1"
)

// The referral programme.
//
// THE RULES, decided by the owner on 2026-10-16 and bounded in code:
//
//	ONE FLAT TIER. A referrer's cut and a buyer's discount are two fixed
//	percentages. Nothing escalates with how old a name is or how long
//	its holder has been here: tenure could be bought (an old name keeps
//	its registration date through a sale), and an escalating table was
//	the reason a second wallet's code was worth up to 37% off.
//
//	AT MOST 10% TOGETHER. Cut plus discount never exceeds maxRefPercent,
//	whatever an admin stores; SetReferralRules refuses more, and the
//	reader clamps anything stored before. An admin can lower it, never
//	raise it.
//
//	FIRST YEAR ONLY. The cut and the discount apply to the registration,
//	which buys the first term. Renewals pay full price and pay nobody.
//
//	A CODE MUST HAVE BEEN HELD. A code earns only when it names a PAID
//	(not free-tier) name that its holder has kept for refHoldDays, by
//	the registry's own holding clock (nsdata.GetNameHeldSince). A wallet
//	made this morning, with a name bought this morning, is no referrer.
//
// What that does to the second-wallet trick: a buyer who quotes the code
// of a second wallet they control saves the discount and recovers the cut
// — at most 10% of the price, after waiting thirty days with a paid name
// in that wallet. TestASecondWalletEarnsAtMostTenPercent pins the number.
//
// SINGLE LEVEL, ALWAYS. One buyer, one referrer, one cut, taken out of
// an actual sale. There is no downline, no override on somebody else's
// referrals, and no bonus for recruiting other referrers — and there is
// no code here that could be extended into one without being obvious
// about it. That is the line between an affiliate programme and the
// other thing, and this realm stays on the near side of it.
//
// WHERE THE LINK LIVES. The referrer is recorded on the REFERRED NAME,
// in its extension slot, at the moment it is registered — a record of
// who brought the buyer, nothing that pays out any more. The vault
// destroys a name's extras when a lapsed name is re-registered and hides
// them the moment it changes hands, so a name that lapses or is sold
// forgets its referrer with no code here to make it so.
//
// WHO GETS PAID. The referrer's own address, fixed, at the moment of the
// sale (see PayoutFor). Nothing accrues and nothing is owed later: the
// cut is paid inside the registration or not at all.
//
// SELF-REFERRAL IS REFUSED. Otherwise the informed apply their own code
// and the cut becomes a silent discount for people who read the source.
//
// EVERYTHING SETTLES IN ONE TRANSACTION. Buyer pays, treasury is paid,
// referrer is paid, overpayment goes back — all inside the message the
// buyer signed. No escrow, no float, not for a block.
const (
	keyRef      = "ref"     // on a NAME: the referrer's address
	keyRefCut   = "refcut"  // global: the referrer's percentage, stored "0:N"
	keyRefDisc  = "refdisc" // global: the buyer's discount, stored "0:N"
	keyRefCount = "rc"      // ACCOUNT field (nsdata's per-address store): how many referred
	keyRefWin   = "refwin"  // global: days a captured code stays valid

	maxRefPercent = 10 // cut plus discount, together; an admin may lower it, never exceed it
	refHoldDays   = 30 // a code earns only once its holder has kept a paid name this long
)

// -- the rates --

// tierPercent reads a stored rate. The canonical form is a one-tier table
// at year zero, "0:N", which every reader of the old escalating tables —
// the site among them — reads as N at any tenure. A legacy multi-tier
// table counts only at year zero (RefRates asks for nothing else), so a
// table that once escalated cannot escalate now. Junk entries are
// skipped, not fatal, so one bad character cannot stop every sale; a
// percentage above the cap is clamped.
func tierPercent(spec string, years int64) int64 {
	best := int64(0)
	bestAt := int64(-1) // the threshold of the tier `best` came from
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
		// The highest tier that applies, not the biggest number in the
		// table, so a table that tapers means what it reads as.
		if years >= at && at >= bestAt {
			bestAt = at
			best = pct
		}
	}
	return best
}

// RefRates is the flat cut and discount in force, in percent, clamped so
// that together they never exceed maxRefPercent whatever is stored. The
// discount is kept and the cut gives way: what a buyer was quoted is the
// promise, the cut is the treasury's to shrink.
func RefRates() (cutPct, discountPct int64) {
	return clampRates(tierPercent(RefCutRules(), 0), tierPercent(RefDiscountRules(), 0))
}

// clampRates is the 10% ceiling on its own, so it can be tested without a
// vault: negative inputs are zero, the discount is capped first, and the
// cut takes whatever room is left.
func clampRates(cut, disc int64) (int64, int64) {
	if cut < 0 {
		cut = 0
	}
	if disc < 0 {
		disc = 0
	}
	if disc > maxRefPercent {
		disc = maxRefPercent
	}
	if cut > maxRefPercent-disc {
		cut = maxRefPercent - disc
	}
	return cut, disc
}

// THE PRESET THE PROJECT LAUNCHES WITH: five percent to the referrer, five
// off for the buyer — the whole 10% the owner allowed, split evenly.
// Written here rather than typed into the admin panel at launch because a
// number that exists only in somebody's memory of a conversation gets set
// wrong once and noticed a month later. It is a DEFAULT, not a policy:
// SetReferralRules overwrites it, and empty rates switch the programme off.
const (
	defaultRefCut      = "0:5"
	defaultRefDiscount = "0:5"
)

// DefaultReferralRules lets the site show the presets before anybody
// commits them.
func DefaultReferralRules() (cut, discount string) {
	return defaultRefCut, defaultRefDiscount
}

// SeedReferralRules writes the presets, and ONLY into empty rates. Not an
// init(): at init a fresh logic realm is not yet trusted by the vault.
// Refusing to overwrite makes it safe to call twice and safe to call by
// mistake.
func SeedReferralRules(cur realm) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if nsdata.GetGlobal(keyRefCut) != "" || nsdata.GetGlobal(keyRefDisc) != "" {
		panic("nslogic: referral rules are already set; use SetReferralRules to change them")
	}
	SetReferralRules(cur, defaultRefCut, defaultRefDiscount)
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
	emitAdmin(cur, "SetReferralWindow", "days", fmtInt(days))
	if days < 0 || days > 3650 {
		panic("nslogic: window must be 0-3650 days")
	}
	setGlobal(cur, keyRefWin, strconv.FormatInt(days, 10))
}

// ReferralQuote is what a code is worth, answered before anybody signs
// anything. One call rather than four, because the site needs all of it
// at once to show a price.
//
// A referrer of "" means the code does not earn — it did not resolve, it
// is the buyer's own, it names a free-tier name, or its holder has not
// kept it for refHoldDays — and both percentages are then zero. `tenure`
// is the referrer's years held, for display only: it no longer moves
// either percentage.
func ReferralQuote(refName string, buyer address) (referrer address, tenure, discountPct, cutPct int64) {
	ref := resolveReferrer(refName, buyer)
	if ref == "" {
		return "", 0, 0, 0
	}
	cut, disc := RefRates()
	return ref, TenureYears(ref), disc, cut
}

// SetReferralRules sets both rates at once, because setting one without
// the other is how a cut ends up larger than the margin. Each is "N" or
// "0:N" (percent), or empty for none; two empties switch the programme
// off. Together they may not exceed maxRefPercent. A multi-tier table is
// refused: the programme has one tier.
func SetReferralRules(cur realm, cutSpec, discountSpec string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SetReferralRules", "cut", cutSpec, "discount", discountSpec)
	cut, cutPct := normalizeRate(cutSpec)
	disc, discPct := normalizeRate(discountSpec)
	if cutPct+discPct > maxRefPercent {
		panic("nslogic: a referrer's cut plus a buyer's discount may be at most " +
			strconv.Itoa(maxRefPercent) + "% — got " + strconv.FormatInt(cutPct+discPct, 10) + "%")
	}
	setGlobal(cur, keyRefCut, cut)
	setGlobal(cur, keyRefDisc, disc)
}

// normalizeRate reads one rate as an admin types it — "5", "0:5", or ""
// — and returns its stored form, "0:5" or "" for none, and the percent.
// Anything else panics before it can reach storage.
func normalizeRate(spec string) (stored string, pct int64) {
	s := strings.TrimSpace(spec)
	if s == "" {
		return "", 0
	}
	if kv := strings.SplitN(s, ":", 2); len(kv) == 2 {
		if strings.TrimSpace(kv[0]) != "0" {
			panic("nslogic: the referral programme has one flat tier; write N or 0:N — got " + spec)
		}
		s = strings.TrimSpace(kv[1])
	}
	p, err := strconv.ParseInt(s, 10, 64)
	if err != nil || p < 0 || p > maxRefPercent {
		panic("nslogic: a referral rate is a whole percent, 0-" + strconv.Itoa(maxRefPercent) + " — got " + spec)
	}
	if p == 0 {
		return "", 0
	}
	return "0:" + strconv.FormatInt(p, 10), p
}

// -- tenure, for display --

// TenureYears is how long a wallet counts as having been here, measured
// from its PRIMARY name. It used to pick the referral tier; it moves no
// money now, and stays because the referral page shows it.
//
// A lapsed or missing primary is zero years, not an error.
func TenureYears(who address) int64 {
	/* RESOLVED, NOT READ RAW. GetPrimary reports what an address last
	   SELECTED, not what it still holds — and a sale on the token ledger
	   no longer clears the seller's pointer. ResolveAddress re-checks the
	   owner and the expiry. */
	tid := ResolveAddress(who)
	at := strings.Index(tid, "*")
	if at < 1 {
		return 0
	}
	_, _, _, streak, _, _ := nsdata.GetNameInfo(tid[:at], tid[at+1:])
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

/*
resolveReferrer turns a claimed referring NAME into the wallet to credit,
or the empty address if the claim does not stand up. Every rejection is
silent on purpose: a mistyped code should not fail somebody's
registration, it should simply earn nobody anything.

THE CODE ITSELF must qualify: a paid name, live, held by its current
holder for refHoldDays. Checking the code rather than "any name the
referrer has" is one lookup instead of a registry walk, and the site
builds a holder's link from a name that qualifies.
*/
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
	if !nsdata.IsNamePaid(label, domainLabel) {
		return "" // a free-tier name is not a code
	}
	if !heldLongEnough(nsdata.GetNameHeldSince(label, domainLabel), time.Now().Unix()) {
		return "" // not held long enough, or bought and not yet seen by the registry
	}
	return owner
}

// heldLongEnough is the thirty-day rule on its own. A zero `since` means
// the registry has not seen the current holder yet — never long enough.
func heldLongEnough(since, now int64) bool {
	return since > 0 && now >= since && now-since >= refHoldDays*86400
}

/*
StartReferralClock starts the holding clock on a name the caller BOUGHT,
so that thirty days later it can be a referral code.

A sale that settles on the token ledger never calls the registry, so the
registry first sees a buyer at their first write to the name. A buyer who
never edits a profile would otherwise never qualify. This is that first
write, with nothing in it: it clears the seller's stale data, which every
read already hides, and stamps the clock. Names you registered yourself
start their clock at registration and need nothing.
*/
func StartReferralClock(cur realm, label, domainLabel string) {
	assertNoSend(cur)
	assertNameOwner(cur, label, domainLabel)
	if err := nsdata.FreshenNameRecord(cross(cur), label, domainLabel); err != nil {
		panic("nslogic: " + err.Error())
	}
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
	if resolveReferrer(refName, buyer) == "" {
		return price
	}
	_, disc := RefRates()
	return price - price*disc/100
}

// referralCut is what leaves for a qualifying referrer out of a
// registration's payment of `price` (already discounted). Returns the
// destination and the amount; the caller pays it in the same call that
// pays the treasury. Registration only: renewals pay nobody.
func referralCut(ref address, price int64) (address, int64) {
	if ref == "" || price <= 0 {
		return "", 0
	}
	cutPct, _ := RefRates()
	cut := price * cutPct / 100
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
// The registrant's transaction pays for this entry: one small field,
// written once per referrer and overwritten after — the price of the
// discount they just received.
//
// IT LIVES IN THE VAULT'S PER-ADDRESS STORE, and until it did, no referred
// registration ever succeeded. It was the global "ref:" + address, 44
// bytes against a 32-byte cap on global keys; the vault refused it, this
// panicked, and the whole purchase reverted after the price was taken —
// on every chain the programme ran on. A key that short would only have
// moved the failure: globals held at most 24 entries, shared with the
// price list, so it would have broken again at about the twenty-first
// referrer. An address is a key there now, and each wallet's fields are
// bounded on their own.
func creditReferral(cur realm, ref address) {
	if ref == "" {
		return
	}
	if err := nsdata.SetAccountRecord(cross(cur), ref, keyRefCount,
		strconv.FormatInt(ReferralCount(ref)+1, 10)); err != nil {
		panic("nslogic: " + err.Error())
	}
}

// ReferralCount is how many paid registrations a wallet has been
// credited with. Public, like everything in the vault.
func ReferralCount(who address) int64 {
	return parseInt64(nsdata.GetAccount(who, keyRefCount))
}

func parseInt64(s string) int64 {
	v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0
	}
	return v
}

// How many vault pages one ReferralBoard call may scan.
const refBoardPages = 5

// ReferralBoard pages through every credited wallet for the
// leaderboard: one "address,count" row per line.
//
// It walks the vault's per-address store, where other fields (credits)
// sit beside the counters, so a page can scan more keys than it returns.
// `next` is an opaque cursor — pass it back as `after` — and is non-empty
// whenever the walk stopped before the end, including when it stopped on
// its scanning budget with fewer rows than asked for. A caller keeps
// going until `next` is empty.
func ReferralBoard(after string, limit int) (rows, next string) {
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	var out []string
	from := after
	for page := 0; page < refBoardPages; page++ {
		keys, more := nsdata.ExportAccounts(from, 200)
		if keys == "" {
			return strings.Join(out, "\n"), ""
		}
		for _, k := range strings.Split(keys, ",") {
			from = k
			at := strings.Index(k, ":")
			if at < 0 || k[at+1:] != keyRefCount {
				continue
			}
			addr := k[:at]
			n := ReferralCount(address(addr))
			if n <= 0 {
				continue
			}
			out = append(out, addr+","+strconv.FormatInt(n, 10))
			if len(out) >= limit {
				return strings.Join(out, "\n"), k
			}
		}
		if more == "" {
			return strings.Join(out, "\n"), ""
		}
	}
	return strings.Join(out, "\n"), from
}
