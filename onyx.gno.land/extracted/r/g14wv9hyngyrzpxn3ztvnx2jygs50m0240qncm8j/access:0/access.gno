// GnoPulse access: on-chain subscriptions + prepaid credits that gate the GnoPulse API.
// Users pay from their own wallet; the realm holds only what they pay it.
package access

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"
)

var (
	// The GnoPulse owner wallet. Cold by design: it signs the deploy and SetOperator,
	// and nothing on a schedule. Every recurring job runs as the operator instead.
	owner = address("g138mdf0gqzue3ra2r335upclngn8t8r0n72cn3h")

	// What a period costs, stated in USD. This is the price; the GNOT figure is derived from it.
	// It is recorded on chain so anyone can check a posted quote against a published GNOT price
	// and see that we quoted honestly.
	priceUsdCents int64 = 2500
	periodSec     int64 = 30 * 24 * 60 * 60

	// A credit IS one API cost-unit. There is no second conversion: the old model bought credits
	// per ugnot and burned 100 of them per unit, which made credits GNOT-denominated while the
	// subscription was USD-denominated, so the two drifted apart whenever GNOT moved.
	//
	// Now both are priced the same way. One cent buys creditsPerUsdCent units, converted from the
	// payment at the live quote, so topping up N GNOT buys whatever N GNOT is worth in dollars.
	// 1600 units per cent is $6.25 per million, three times the rate a subscription includes,
	// which is the overage premium this pricing was set to. It is exact in integer math: a
	// million units is 625 cents with no remainder.
	creditsPerUsdCent int64 = 1600

	// TopUp multiplies the payment by priceUsdCents and creditsPerUsdCent before dividing, so a
	// large enough payment would overflow int64 before the divide. A million GNOT is far beyond
	// any real top-up and leaves three orders of magnitude of headroom.
	maxTopUpUgnot int64 = 1_000_000_000_000

	// --- the quote ---------------------------------------------------------------------------
	//
	// A fiat price in a volatile coin is quoted, not computed at settlement. We convert
	// priceUsdCents to ugnot off chain (where the price feed is) and post the result here; that
	// number IS the obligation until it expires. The payment page reads quoteUgnot from this
	// realm rather than from any feed of ours, so the figure on screen and the figure charged are
	// the same number by construction, never merely close.
	//
	// This is what payment processors do, and expiry is the rate lock: BitPay locks a quote for
	// 15 minutes, BTCPay for 15, NOWPayments for 10. Slippage is a trading idea and has no place
	// here; nobody shows one number and charges another.
	quoteUgnot int64 // ugnot for one period
	quotedAt   int64 // when it was posted

	// The superseded quote stays payable for a grace window, so a payer who was quoted a moment
	// before we posted a new number still pays what they were shown rather than being repriced
	// mid-flight. currentPrice charges whichever of the two is lower while both are live.
	prevUgnot int64
	prevUntil int64

	// How long a posted quote is good for, and how long a superseded one stays payable. If the
	// job that posts quotes stops, Subscribe refuses rather than pricing off a stale number: a
	// broken cron becomes failed payments, never wrong charges.
	quoteTtlSec   int64 = 900
	quoteGraceSec int64 = 900

	// The grace window exists so a small tick does not reprice a payment in flight. It must NOT
	// survive a correction: currentPrice charges the LOWER of the two live quotes, so carrying a
	// wildly wrong quote forward means posting the right one keeps the wrong one payable for a
	// FRESH grace window. Correcting the mistake would extend it past the point it would have
	// lapsed on its own. A move of this factor or more is treated as a correction, not a tick,
	// and the old quote is dropped instead of carried.
	quoteGraceBand int64 = 4

	// Ownership moves in two steps. A single-step transfer to a mistyped address is
	// unrecoverable here: address is an unvalidated string type, so any non-empty value is
	// accepted, and the realm is immutable, so a wrong owner locks Withdraw and every admin
	// function forever. The offer sits here until the named address claims it itself, which is
	// proof the key exists and can transact.
	pendingOwner address

	// operator is the HOT role. Two of the owner's jobs are not administrative at all: SetQuote
	// runs every five minutes and Consume every six hours, both from an unattended cron on a
	// public-facing box. With one role, automating them means the key that can Withdraw must sit
	// in a keybase on that box. Splitting them means a stolen box costs quote posting, not the
	// revenue: an operator can price and settle, and can do nothing else.
	//
	// Empty disables it, and that is the kill switch. The owner revokes a suspect operator in one
	// transaction from their own wallet, without touching anything else.
	operator address

	subs    = map[address]int64{} // addr -> expiry (unix)
	credits = map[address]int64{} // addr -> credit balance

	// settled is the billing watermark: cumulative API cost-units already charged to an address.
	// It lives on chain so that losing or restoring our off-chain database cannot re-bill usage
	// that was already paid for -- Consume rejects any total at or below what it already settled.
	settled = map[address]int64{}
)

// Subscribe buys pro time for the caller at the live quote. Each whole quote sent buys one
// period; anything left over becomes units at the same rate a top-up gets, rather than being
// kept, so the payer keeps the value of every ugnot they sent.
//
// Every call is priced at the quote in force when it executes, so a renewal costs what a period
// costs today. Pinning a renewal to the price paid at first purchase is a known trap: Unlock
// Protocol does it and a renewal simply reverts once the price has moved.
func Subscribe(cur realm) {
	runtime.AssertOriginCall()
	subscribe(cur.Previous().Address(), int64(unsafe.OriginSend().AmountOf("ugnot")))
}

// subscribe holds the money math, separate from the origin/caller plumbing above so it can be
// exercised directly (AssertOriginCall cannot be satisfied from a test frame).
func subscribe(payer address, paid int64) {
	price := currentPrice()
	if paid < price {
		// Underpayment is refused outright, which is what every processor surveyed does: BitPay
		// voids the whole payment, BTCPay defaults its tolerance to zero.
		panic("payment below the quoted price")
	}
	base := subs[payer]
	if now := time.Now().Unix(); base < now {
		base = now
	}
	subs[payer] = base + (paid/price)*periodSec
	change := unitsFor(paid%price, price)
	if change > 0 {
		credits[payer] += change
	}
	chain.Emit("Subscribe",
		"addr", payer.String(),
		"paid", strconv.FormatInt(paid, 10),
		"expiresAt", strconv.FormatInt(subs[payer], 10),
		"changeUnits", strconv.FormatInt(change, 10))
}

// Login does nothing. Sign-In-With-Gno signs (never broadcasts) a call to it so the wallet shows
// a "Login" to GnoPulse rather than a token transfer; the challenge nonce rides in the tx memo.
func Login(cur realm) {
	// Login credits nothing, so coins sent with it would be kept by the realm with no record and
	// no way to return them. Refuse instead.
	if int64(unsafe.OriginSend().AmountOf("ugnot")) > 0 {
		panic("Login takes no payment")
	}
}

// TopUp buys prepaid credits for the caller.
func TopUp(cur realm) {
	runtime.AssertOriginCall()
	topUp(cur.Previous().Address(), int64(unsafe.OriginSend().AmountOf("ugnot")))
}

// topUp converts the payment to units at the SAME quote the subscription uses, so a credit is
// worth the same in dollars whatever GNOT is doing. Paying in GNOT, priced in USD.
func topUp(payer address, paid int64) {
	if paid <= 0 {
		panic("no payment")
	}
	if paid > maxTopUpUgnot {
		panic("payment too large")
	}
	// currentPrice is the live quote (with the same grace window Subscribe gets), and it panics
	// when there is none: pegging credits to USD means credits need a rate too, so a dead quote
	// job closes top-ups as well as subscriptions rather than selling at a stale rate.
	got := unitsFor(paid, currentPrice())
	if got <= 0 {
		panic("payment too small to buy a unit")
	}
	credits[payer] += got
	chain.Emit("TopUp",
		"addr", payer.String(),
		"paid", strconv.FormatInt(paid, 10),
		"units", strconv.FormatInt(got, 10),
		"balance", strconv.FormatInt(credits[payer], 10))
}

// unitsFor converts a ugnot payment into API units at a given quote. The payment is worth
// paid/price of a period, a period costs priceUsdCents, and one cent buys creditsPerUsdCent
// units. One helper so a top-up and the change from a subscription can never diverge.
func unitsFor(paid, price int64) int64 {
	return paid * priceUsdCents * creditsPerUsdCent / price
}

func HasAccess(addr address) bool { return subs[addr] > time.Now().Unix() || credits[addr] > 0 }

func TierOf(addr address) string {
	if subs[addr] > time.Now().Unix() {
		return "pro"
	}
	return "free"
}

func CreditsOf(addr address) int64 { return credits[addr] }
func ExpiresAt(addr address) int64 { return subs[addr] }
func SettledOf(addr address) int64 { return settled[addr] }
func Owner() address               { return owner }

func Config() (int64, int64, int64, int64, int64) {
	return priceUsdCents, periodSec, creditsPerUsdCent, quoteTtlSec, quoteGraceSec
}

// Consume charges an address for metered API usage, up to a cumulative cost-unit total.
//
// The owner passes the caller's running lifetime usage, not a delta: the realm keeps the
// watermark itself and charges only the part it has not charged before. That makes the call
// idempotent (a replay is rejected, not re-billed) and means a restored or rolled-back
// off-chain database cannot double-charge anyone.
//
// A caller with too few credits is charged what they have and the watermark still advances; the
// event records both what was owed and what was actually taken, so a shortfall is visible rather
// than silently forgiven.
func Consume(cur realm, addr address, uptoUnits int64) {
	assertOperator(cur)
	consume(addr, uptoUnits)
}

func consume(addr address, uptoUnits int64) {
	prev := settled[addr]
	if uptoUnits <= prev {
		panic("already settled to that total")
	}
	owed := uptoUnits - prev
	took := owed
	if have := credits[addr]; have <= owed {
		took = have
		delete(credits, addr)
	} else {
		credits[addr] = have - owed
	}
	settled[addr] = uptoUnits
	chain.Emit("Consume",
		"addr", addr.String(),
		"units", strconv.FormatInt(uptoUnits-prev, 10),
		"settledTo", strconv.FormatInt(uptoUnits, 10),
		"owed", strconv.FormatInt(owed, 10),
		"debited", strconv.FormatInt(took, 10),
		"remaining", strconv.FormatInt(credits[addr], 10))
}

// Forgive advances the billing watermark without charging: usage already covered by an active
// time-based subscription. Separate from Consume so that "we decided not to bill this" is its own
// auditable on-chain act rather than an invisible gap in the watermark.
func Forgive(cur realm, addr address, uptoUnits int64) {
	assertOwner(cur)
	forgive(addr, uptoUnits)
}

func forgive(addr address, uptoUnits int64) {
	prev := settled[addr]
	if uptoUnits <= prev {
		panic("already settled to that total")
	}
	settled[addr] = uptoUnits
	chain.Emit("Forgive",
		"addr", addr.String(),
		"units", strconv.FormatInt(uptoUnits-prev, 10),
		"settledTo", strconv.FormatInt(uptoUnits, 10))
}

// SetQuote posts the price of one period in ugnot. Called on a short schedule by the job that
// already tracks the GNOT price, which converts priceUsdCents off chain and publishes only the
// result. The previous quote stays payable for quoteGraceSec so payments already in flight are
// not repriced.
func SetQuote(cur realm, ugnotPerPeriod int64) {
	assertOperator(cur)
	setQuote(ugnotPerPeriod)
}

func setQuote(ugnotPerPeriod int64) {
	if ugnotPerPeriod <= 0 {
		panic("quote must be positive")
	}
	now := time.Now().Unix()
	if quoteUgnot > 0 && ugnotPerPeriod/quoteUgnot < quoteGraceBand && quoteUgnot/ugnotPerPeriod < quoteGraceBand {
		prevUgnot, prevUntil = quoteUgnot, now+quoteGraceSec
	} else {
		// A correction (or the first quote). Drop any standing grace rather than let the
		// superseded number stay payable.
		prevUgnot, prevUntil = 0, 0
	}
	quoteUgnot, quotedAt = ugnotPerPeriod, now
	chain.Emit("SetQuote",
		"ugnot", strconv.FormatInt(ugnotPerPeriod, 10),
		"usdCents", strconv.FormatInt(priceUsdCents, 10),
		"expiresAt", strconv.FormatInt(now+quoteTtlSec, 10))
}

// Quote is what the payment page reads: the amount to send for one period, and the moment it
// stops being honoured. Reading it from here rather than from a price feed is what makes the
// figure on screen and the figure charged the same number.
func Quote() (int64, int64, int64) {
	return quoteUgnot, quotedAt, quotedAt + quoteTtlSec
}

// currentPrice is what Subscribe charges. While a superseded quote is still inside its grace
// window both are live, and the payer is charged the lower of the two: we cannot tell which one
// they were shown, and charging the lower one guarantees it is never more than they saw.
func currentPrice() int64 {
	now := time.Now().Unix()
	if quoteUgnot <= 0 {
		panic("no quote has been posted")
	}
	if now > quotedAt+quoteTtlSec {
		panic("the quote has expired")
	}
	if prevUgnot > 0 && now <= prevUntil && prevUgnot < quoteUgnot {
		return prevUgnot
	}
	return quoteUgnot
}

func SetConfig(cur realm, cents, period, perUsdCent, ttl, grace int64) {
	assertOwner(cur)
	setConfig(cents, period, perUsdCent, ttl, grace)
}

func setConfig(cents, period, perUsdCent, ttl, grace int64) {
	if cents <= 0 || period <= 0 || perUsdCent <= 0 || ttl <= 0 || grace < 0 {
		panic("must be positive")
	}
	priceUsdCents, periodSec, creditsPerUsdCent = cents, period, perUsdCent
	quoteTtlSec, quoteGraceSec = ttl, grace
	chain.Emit("SetConfig",
		"usdCents", strconv.FormatInt(cents, 10),
		"period", strconv.FormatInt(period, 10),
		"creditsPerUsdCent", strconv.FormatInt(perUsdCent, 10),
		"quoteTtl", strconv.FormatInt(ttl, 10),
		"quoteGrace", strconv.FormatInt(grace, 10))
}

func Withdraw(cur realm, amount int64) {
	assertOwner(cur)
	if amount <= 0 {
		panic("must be positive")
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
		cur.Address(), owner, chain.Coins{{"ugnot", amount}})
	chain.Emit("Withdraw", "amount", strconv.FormatInt(amount, 10))
}

// TransferOwnership OFFERS the realm to newOwner. It does not hand it over: the offer stands
// until that address claims it with AcceptOwnership. A mistyped address therefore costs nothing,
// where a single-step transfer would have locked every admin function and the revenue behind an
// address nobody holds, permanently, because the realm cannot be redeployed.
func TransferOwnership(cur realm, newOwner address) {
	assertOwner(cur)
	transferOwnership(newOwner)
}

// transferOwnership holds the offer itself, split from the owner gate above for the same reason
// subscribe is split from Subscribe: assertOwner cannot be satisfied from a test frame.
func transferOwnership(newOwner address) {
	if newOwner == "" {
		panic("empty address")
	}
	pendingOwner = newOwner
	chain.Emit("OwnershipOffered", "from", owner.String(), "to", newOwner.String())
}

// CancelOwnershipTransfer withdraws a standing offer.
func CancelOwnershipTransfer(cur realm) {
	assertOwner(cur)
	pendingOwner = ""
	chain.Emit("OwnershipOfferCancelled")
}

// AcceptOwnership completes the handover. Only the offered address can call it, which proves the
// key exists and can sign before anything irreversible happens.
func AcceptOwnership(cur realm) {
	acceptOwnership(cur.Previous().Address())
}

func acceptOwnership(caller address) {
	if pendingOwner == "" || caller != pendingOwner {
		panic("not the pending owner")
	}
	prev := owner
	owner, pendingOwner = caller, ""
	chain.Emit("TransferOwnership", "from", prev.String(), "to", owner.String())
}

func PendingOwner() address { return pendingOwner }

// SetOperator appoints, rotates or (with an empty address) revokes the hot role.
//
// One step, unlike TransferOwnership, and the asymmetry is deliberate: a mistyped owner is
// permanent and locks the revenue, while a mistyped operator only means quotes stop until the
// owner sets it again. Making revocation a two-step handshake would be worse than useless, since
// the address being revoked is the one you no longer trust to act.
func SetOperator(cur realm, op address) {
	assertOwner(cur)
	setOperator(op)
}

func setOperator(op address) {
	prev := operator
	operator = op
	chain.Emit("SetOperator", "from", prev.String(), "to", op.String())
}

func Operator() address { return operator }

// assertOwner requires a DIRECT call from the owner. cur.Previous() is the immediate caller, so a
// relaying realm (owner -> X -> here) would fail this, no separate origin assert needed.
func assertOwner(cur realm) {
	if cur.Previous().Address() != owner {
		panic("owner only")
	}
}

// isOperator is the routine-work gate as a pure predicate, so it is unit-testable: assertOperator
// below cannot be satisfied from a test frame, exactly as assertOwner cannot.
//
// The owner always passes. A fresh deploy has no operator yet, so the owner must be able to post
// the first quote or the realm is unusable until one is appointed, and the owner must be able to
// take over the moment an operator is revoked.
func isOperator(caller address) bool {
	return caller == owner || (operator != "" && caller == operator)
}

// assertOperator gates the two jobs that run on a schedule. Everything that moves money or changes
// the terms stays behind assertOwner, including Forgive, which is the repair for an operator that
// over-charges and therefore must never be reachable by one.
func assertOperator(cur realm) {
	if !isOperator(cur.Previous().Address()) {
		panic("owner or operator only")
	}
}

func Render(path string) string {
	if len(path) > 5 && path[:5] == "addr/" {
		a := address(path[5:])
		return "# " + a.String() + "\n\n- tier: " + TierOf(a) +
			"\n- expires: " + strconv.FormatInt(subs[a], 10) +
			"\n- credits: " + strconv.FormatInt(credits[a], 10) +
			"\n- billed through: " + strconv.FormatInt(settled[a], 10) + " cost-units\n"
	}
	// Three states, not two. The old text had one branch for "quoteUgnot > 0" and called
	// everything else "subscriptions are closed", which is wrong twice over on an immutable page:
	// a LAPSED quote still rendered as "good until <a timestamp in the past>", and a merely absent
	// quote was announced as the shop being shut. A quote is posted on request and lives for
	// quoteTtlSec, so "none standing" is the ordinary resting state, not a fault, and this page
	// cannot tell a quiet moment from an outage. It says what it knows and no more.
	quoteLine := "- quote: none standing. One is posted on request and is good for " +
		strconv.FormatInt(quoteTtlSec, 10) + "s once posted.\n"
	if quoteUgnot > 0 {
		if time.Now().Unix() <= quotedAt+quoteTtlSec {
			quoteLine = "- quote: " + strconv.FormatInt(quoteUgnot, 10) + " ugnot / " +
				strconv.FormatInt(periodSec, 10) + "s, good until " +
				strconv.FormatInt(quotedAt+quoteTtlSec, 10) + "\n"
		} else {
			quoteLine = "- quote: the last one lapsed at " +
				strconv.FormatInt(quotedAt+quoteTtlSec, 10) +
				". A fresh quote is posted on request.\n"
		}
	}
	return "# GnoPulse Access\n\nSubscribe() or TopUp() from your wallet. Send exactly the quote " +
		"below; it is what you will be charged.\n\n" +
		"- price: $" + usd(priceUsdCents) + " per " + strconv.FormatInt(periodSec, 10) + "s\n" +
		quoteLine +
		"- credits: " + strconv.FormatInt(creditsPerUsdCent, 10) +
		" API units per US cent, bought at the quote above\n"
}

// usd renders cents as dollars, keeping the two decimal places (2500 -> "25.00", 2505 -> "25.05").
func usd(cents int64) string {
	c := cents % 100
	pad := "."
	if c < 10 {
		pad = ".0"
	}
	return strconv.FormatInt(cents/100, 10) + pad + strconv.FormatInt(c, 10)
}
