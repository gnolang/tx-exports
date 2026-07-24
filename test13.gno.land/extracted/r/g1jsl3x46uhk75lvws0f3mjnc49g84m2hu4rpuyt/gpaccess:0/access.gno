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
	owner = address("g1jsl3x46uhk75lvws0f3mjnc49g84m2hu4rpuyt")

	priceUgnot int64 = 5_000_000
	periodSec  int64 = 30 * 24 * 60 * 60
	creditRate int64 = 1

	subs    = map[address]int64{} // addr -> expiry (unix)
	credits = map[address]int64{} // addr -> credit balance
)

// Subscribe buys pro time for the caller; each price unit sent buys one period.
func Subscribe(cur realm) {
	runtime.AssertOriginCall()
	payer := cur.Previous().Address()
	paid := int64(unsafe.OriginSend().AmountOf("ugnot"))
	if paid < priceUgnot {
		panic("payment below price")
	}
	base := subs[payer]
	if now := time.Now().Unix(); base < now {
		base = now
	}
	subs[payer] = base + (paid/priceUgnot)*periodSec
	chain.Emit("Subscribe", "addr", payer.String(), "expiresAt", strconv.FormatInt(subs[payer], 10))
}

// Login does nothing. Sign-In-With-Gno signs (never broadcasts) a call to it so the wallet shows
// a "Login" to GnoPulse rather than a token transfer; the challenge nonce rides in the tx memo.
func Login(cur realm) {}

// TopUp buys prepaid credits for the caller.
func TopUp(cur realm) {
	runtime.AssertOriginCall()
	payer := cur.Previous().Address()
	paid := int64(unsafe.OriginSend().AmountOf("ugnot"))
	if paid <= 0 {
		panic("no payment")
	}
	credits[payer] += paid * creditRate
	chain.Emit("TopUp", "addr", payer.String(), "credits", strconv.FormatInt(credits[payer], 10))
}

func HasAccess(addr address) bool { return subs[addr] > time.Now().Unix() || credits[addr] > 0 }

func TierOf(addr address) string {
	if subs[addr] > time.Now().Unix() {
		return "pro"
	}
	return "free"
}

func CreditsOf(addr address) int64  { return credits[addr] }
func ExpiresAt(addr address) int64  { return subs[addr] }
func Owner() address                { return owner }
func Config() (int64, int64, int64) { return priceUgnot, periodSec, creditRate }

// Consume debits credits (owner settles metered usage in batches). Floors at zero.
func Consume(cur realm, addr address, n int64) {
	assertOwner(cur)
	if n < 0 {
		panic("negative")
	}
	if credits[addr] <= n {
		delete(credits, addr)
	} else {
		credits[addr] -= n
	}
}

func SetConfig(cur realm, price, period, rate int64) {
	assertOwner(cur)
	if price <= 0 || period <= 0 || rate <= 0 {
		panic("must be positive")
	}
	priceUgnot, periodSec, creditRate = price, period, rate
}

func Withdraw(cur realm, amount int64) {
	assertOwner(cur)
	if amount <= 0 {
		panic("must be positive")
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
		cur.Address(), owner, chain.Coins{{"ugnot", amount}})
}

func TransferOwnership(cur realm, newOwner address) {
	assertOwner(cur)
	if newOwner == "" {
		panic("empty address")
	}
	owner = newOwner
}

// assertOwner requires a DIRECT call from the owner. cur.Previous() is the immediate caller, so a
// relaying realm (owner -> X -> here) would fail this — no separate origin assert needed.
func assertOwner(cur realm) {
	if cur.Previous().Address() != owner {
		panic("owner only")
	}
}

func Render(path string) string {
	if len(path) > 5 && path[:5] == "addr/" {
		a := address(path[5:])
		return "# " + a.String() + "\n\n- tier: " + TierOf(a) +
			"\n- expires: " + strconv.FormatInt(subs[a], 10) +
			"\n- credits: " + strconv.FormatInt(credits[a], 10) + "\n"
	}
	return "# GnoPulse Access\n\nSubscribe() or TopUp() from your wallet.\n\n- price: " +
		strconv.FormatInt(priceUgnot, 10) + " ugnot / " + strconv.FormatInt(periodSec, 10) + "s\n" +
		"- credits: " + strconv.FormatInt(creditRate, 10) + " per ugnot\n"
}
