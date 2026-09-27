// The BUBBLE treasury: where the pools' royalty lands, and the one power that moves it.
//
// Bubble Rumble's pools (v5 on) send 5 % of every boop to an address that belongs to the BUBBLE token realm and to
// nobody else: the token's SUB-realm for the kind published here, `treasury:spend`. A sub-realm is a distinct
// package path (`…/bubble#treasury-spend`) with its own address; it can hold and send coins and can never issue
// tokens. The token's governor hands exactly that sub-realm to this kind's Do when the holders have decided a
// spend, and to nothing else — so the only way a coin leaves the treasury is a proposal under `treasury:spend`,
// adopted by the holders (govern:adopt) and passed on the token's own money terms: a fifth of the supply turning
// out, two thirds yes, a week to vote, two days' delay.
//
// This realm holds no coins and no power of its own. It publishes the kind (Offer, at its deploy), says where the
// treasury is (Address), how much it holds (Balance) and renders the terms. The kind's Do runs inside the token
// realm and crosses back here with the sub-realm's own token to note each spend (noteSpend: the pace lives here);
// nothing else writes here, and what was spent is also on the chain (the TreasurySpend event).
package bubbletreasury

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	governor "gno.land/p/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/governor/v0"
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble"
)

const (
	bubblePath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble"
	ownPath    = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubbletreasury"

	// KindName is what the holders adopt and propose under. The governor derives the sub-realm's path from it:
	// lower-cased, every character outside [a-z0-9] turned into '-' — so `treasury:spend` lives at `treasury-spend`.
	KindName = "treasury:spend"
	subpath  = "treasury-spend"

	one = int64(1_000_000) // ugnot in one GNOT

	// MaxSpend is the most one proposal may move, in whole GNOT — and never more than a QUARTER of what the treasury
	// holds (MaxShare), or SmallTreasury whole GNOT if that is more (so a small treasury can be spent whole, and a
	// treasury just over it has no cliff). The cap bounds one question; the PACE is the window: a window opens at
	// the first spend after Window seconds of none, and the spends in the Window seconds from that first spend
	// together may move at most that same quarter of what the treasury held then (spentAt/windowBase below); the
	// next spend after those seconds opens the next window. So "a quarter per two-day window" is true in code: a
	// majority that wants it all has to say so in public, and wait, several times over.
	MaxSpend      = int64(100_000)
	MaxShare      = int64(4)                // a proposal, and a window, may move at most balance/MaxShare…
	SmallTreasury = int64(40)               // …or this many whole GNOT, whichever is more (up to the balance)
	Window        = int64(2 * 24 * 60 * 60) // seconds: the pace — one quarter per window
)

// Offer, at deploy: the kind is published in the same transaction that stores this realm, so there is no window
// in which somebody else can bind the name first (r/bubble's Offer is open to anyone and a name, once taken, is
// taken for good). If the name IS taken by then, the deploy fails as a whole and this realm is redeployed under a
// name that maps to the same sub-path (see Recovery in the plan) — nothing has been paid to the address yet.
func init(cur realm) {
	bubble.Offer(cross(cur), spendKind{}, governor.BootstrapRules())
	offered = true
}

// poolRealms are the game's realms: a spend to one of their addresses would strand the coins (a realm's balance is
// not a bubble's pot), and "seed a bubble" is exactly the spend the holders will think of first.
var poolRealms = []string{
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble",
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble2",
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble3",
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble4",
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble5",
}

var (
	// treasury is the address the pools pay: the token realm's sub-realm for the kind. Pure arithmetic on the two
	// paths (chain.DerivePkgSubAddr), the same the VM does when the token realm runs the kind.
	treasury = chain.DerivePkgSubAddr(bubblePath, subpath)
	offered  bool
	// spentAt is the height of the last spend: ONE spend per block. The governor's own govern:batch runs every
	// member of a decided batch in one transaction, and each member's Check sees the balance before any of them
	// ran — so a ladder of quarter-sized lines (25, 18, 14, 10 … of 100) would pass every cap and drain the
	// treasury in one vote. A second spend in the block a spend already landed in aborts instead (Do panics: the
	// transaction unwinds, nothing moves, the proposal stays decided and runs in a later block); a batch of two
	// spends therefore never runs at all. So "a quarter at a time" means a quarter per vote, as it should.
	spentAt int64
	spends  int64 // spends executed, ever
	spent   int64 // ugnot moved out, ever
	// the window: opened by the first spend after Window seconds of none; what it may move is the cap for what the
	// treasury held then (windowBase), and windowSpent is what it has moved so far
	windowAt    int64 // block time the window opened
	windowBase  int64 // ugnot held when it opened, before its first spend
	windowSpent int64 // ugnot moved in it
)

// WindowLeft is what may still move before the window closes, in ugnot — the whole cap for a window not open.
func WindowLeft() int64 {
	now := time.Now().Unix()
	if windowAt == 0 || now-windowAt >= Window {
		return maxFor(Balance()) * one
	}
	left := maxFor(windowBase)*one - windowSpent
	if left < 0 {
		return 0
	}
	return left
}

// SpentAt is the height of the last spend; Spends and Spent, the count and the sum — the realm's own log.
func SpentAt() int64 { return spentAt }
func Spends() int64  { return spends }
func Spent() int64   { return spent }

// noteSpend is the kind's way to write here: Do runs inside the token realm, which cannot touch this realm's
// variables, so it crosses back with the sub-realm token it was handed — and only that token is let in
// (its address is the treasury). Called BEFORE the coins move; a second call in one block panics so the
// transaction, and with it any batch, unwinds with nothing moved.
func noteSpend(cur realm, amt int64) {
	if cur.Previous().Address() != treasury {
		panic("treasury: only the treasury's own kind may note a spend")
	}
	h := runtime.ChainHeight()
	if h == spentAt {
		panic("treasury: one spend per block — this block already has one; run it again in the next")
	}
	now := time.Now().Unix()
	if windowAt == 0 || now-windowAt >= Window {
		windowAt, windowBase, windowSpent = now, Balance(), 0 // Balance() is read before this spend's send
	}
	if windowSpent+amt > maxFor(windowBase)*one {
		panic("treasury: this window (" + strconv.FormatInt(Window/86400, 10) + " days) has moved its quarter already; run it again when the window has passed")
	}
	windowSpent += amt
	spentAt, spends, spent = h, spends+1, spent+amt
}

// Address is where the royalty goes. Every pool version from v5 pays here; anyone may send here.
func Address() address { return treasury }

// Balance is what the treasury holds right now, in ugnot.
func Balance() int64 { return banker.NewReadonlyBanker().GetCoins(treasury).AmountOf("ugnot") }

// Offered is whether the kind has been published to the token's governor.
func Offered() bool { return offered }

// Offer is the same publication for a realm loaded without its init having run it (a test harness): it does
// nothing once the token's governor knows the name. The holders still have to adopt the kind by vote before a spend
// can be proposed.
func Offer(cur realm) {
	if _, known := bubble.KindRules(KindName); known {
		offered = true
		return
	}
	bubble.Offer(cross(cur), spendKind{}, governor.BootstrapRules())
	offered = true
}

// MaxNow is the most one proposal may move right now, in whole GNOT: the cap for a balance.
func MaxNow() int64 { return maxFor(Balance()) }

func maxFor(balance int64) int64 {
	whole := balance / one
	m := whole / MaxShare
	if m < SmallTreasury {
		m = minInt(whole, SmallTreasury) // a small treasury may go whole; just over it, the same forty — no cliff
	}
	return minInt(m, MaxSpend)
}

func minInt(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

// Preview is what a proposal with this payload would say, and whether it could open now.
func Preview(payload string) string {
	k := spendKind{}
	s := k.Describe(payload)
	if err := k.Check(payload); err != nil {
		return s + " — refused: " + err.Error()
	}
	return s
}

// ---- the kind

type spendKind struct{}

func (spendKind) Name() string { return KindName }

// Describe reads the payload alone: two voters at different heights must see the same question.
func (spendKind) Describe(p string) string {
	to, n, err := parse(p)
	if err != nil {
		return "spend from the BUBBLE treasury: " + p
	}
	return "send " + strconv.FormatInt(n, 10) + " GNOT from the BUBBLE treasury to " + to.String()
}

// Check runs when the proposal opens and again right before Do: the amount must be within the cap both times.
func (spendKind) Check(p string) error {
	_, n, err := parse(p)
	if err != nil {
		return err
	}
	return within(n)
}

// within is the cap for the balance as it stands: the whole of a small treasury, a quarter of a large one.
func within(n int64) error {
	have := Balance()
	if n*one > have {
		return errf("the treasury holds " + gnot(have) + " GNOT, not " + strconv.FormatInt(n, 10))
	}
	if m := maxFor(have); n > m {
		return errf("one proposal may move at most " + strconv.FormatInt(m, 10) + " GNOT of the " + gnot(have) + " held (a quarter, or " + strconv.FormatInt(SmallTreasury, 10) + " whole GNOT if that is more)")
	}
	return nil
}

// Do moves the coins. rlm is the token realm's sub-realm for this kind, handed over by its governor for this one
// decided proposal: its address is the treasury, and RealmSend from it is the only send there is. An error ends
// the proposal as failed with nothing moved; nothing here can half-finish.
func (spendKind) Do(_ int, rlm realm, p string) error {
	to, n, err := parse(p)
	if err != nil {
		return err
	}
	if rlm.Address() != treasury {
		return errf("that is not the treasury's realm") // a governor other than the token's ran this kind
	}
	if err := within(n); err != nil {
		return err
	}
	amt, have := n*one, Balance()
	noteSpend(cross(rlm), amt) // one spend per block: a batch of spends aborts here (see spentAt)
	banker.NewBanker(banker.BankerTypeRealmSend, rlm).SendCoins(treasury, to, chain.Coins{{"ugnot", amt}})
	chain.Emit("TreasurySpend", "to", to.String(), "ugnot", strconv.FormatInt(amt, 10), "left", strconv.FormatInt(have-amt, 10))
	return nil
}

// parse reads "g1… N": an address and whole GNOT, 1 ≤ N ≤ MaxSpend.
func parse(p string) (address, int64, error) {
	parts := strings.Fields(p)
	if len(parts) != 2 {
		return "", 0, errf("expected \"g1… N\": an address and whole GNOT")
	}
	to := address(parts[0])
	if !to.IsValid() {
		return "", 0, errf("not an address")
	}
	if to == treasury || to == chain.PackageAddress(bubblePath) || to == chain.PackageAddress(ownPath) {
		return "", 0, errf("that is a realm of the token's own: coins sent there could never come back")
	}
	for _, r := range poolRealms { // a pool realm's address takes coins into no pool: they would sit there for good
		if to == chain.PackageAddress(r) {
			return "", 0, errf("that is a pool realm's own address: coins sent there join no bubble and never come back (seed a bubble with CreatePool, from a wallet)")
		}
	}
	n, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || n <= 0 || n > MaxSpend {
		return "", 0, errf("expected whole GNOT, between 1 and " + strconv.FormatInt(MaxSpend, 10) + " in one proposal")
	}
	return to, n, nil
}

type treasuryErr struct{ msg string }

func (e *treasuryErr) Error() string { return "treasury: " + e.msg }
func errf(s string) error            { return &treasuryErr{s} }

// gnot prints ugnot as GNOT with up to six decimals, trailing zeros dropped.
func gnot(u int64) string {
	whole, frac := u/one, u%one
	if frac == 0 {
		return strconv.FormatInt(whole, 10)
	}
	f := strconv.FormatInt(frac, 10)
	for len(f) < 6 {
		f = "0" + f
	}
	return strconv.FormatInt(whole, 10) + "." + strings.TrimRight(f, "0")
}

// Render: the treasury for a reader — where, how much, and how it moves.
func Render(path string) string {
	if path == "json" {
		return `{"address":"` + treasury.String() + `","ugnot":` + strconv.FormatInt(Balance(), 10) + `,"kind":"` + KindName + `","offered":` + strconv.FormatBool(offered) + `,"maxSpend":` + strconv.FormatInt(MaxSpend, 10) + `,"maxNow":` + strconv.FormatInt(MaxNow(), 10) + `,"windowLeft":` + strconv.FormatInt(WindowLeft(), 10) + `,"spends":` + strconv.FormatInt(spends, 10) + `,"spent":` + strconv.FormatInt(spent, 10) + `}`
	}
	var b strings.Builder
	b.WriteString("# The BUBBLE treasury\n\n")
	b.WriteString("**" + gnot(Balance()) + " GNOT** at `" + treasury.String() + "` — the token realm's own sub-realm `" + subpath + "`.\n\n")
	b.WriteString("Every Bubble Rumble pool from v5 on sends **5% of every boop's bid** here (not of a bubble's seed, not of shots). Nothing leaves except by a decided vote of the BUBBLE holders under `" + KindName + "`")
	if offered {
		b.WriteString(" (published to the token's governor; the holders adopt it with `govern:adopt`, then anyone may propose `\"g1… N\"` — an address and whole GNOT)")
	} else {
		b.WriteString(" (not yet published: call `Offer` once)")
	}
	b.WriteString(". A proposal may move at most a quarter of what the treasury holds, or " + strconv.FormatInt(SmallTreasury, 10) + " GNOT if that is more, never over " + strconv.FormatInt(MaxSpend, 10) + " — right now " + strconv.FormatInt(MaxNow(), 10) + " GNOT; and the spends in a window — the " + strconv.FormatInt(Window/86400, 10) + " days from its first spend — together may move that same quarter (or " + strconv.FormatInt(SmallTreasury, 10) + ") of what it held then (" + gnot(WindowLeft()) + " GNOT left in the window now); the next spend after those days opens the next window; one spend a block, so a batch of spends cannot run. A quarter per two-day window, whatever is proposed. Only the holders' votes move money, on the token's money terms: a fifth of the supply turning out (this kind takes the plain fifth; the token's own settings raise their bar with past turnout), two thirds yes, a week to vote (or sooner, once the outcome cannot change), two days' delay, a fortnight to run it. Votes count what a wallet held at the last sealed epoch before the question opened. Today the founding share (10,000,000 of the BUBBLE in issue) carries every vote; that thins as referrals mint.\n\n")
	b.WriteString("BUBBLE carries a vote, not a claim: nothing here promises holders a payment from the treasury, and the holders' custom is prizes, work on the game and the token's market. Spends so far: " + strconv.FormatInt(spends, 10) + ", " + gnot(spent) + " GNOT.\n\n")
	b.WriteString("Replacing this kind: a kind under another name that the governor maps to the same sub-path `" + subpath + "` (for example `treasury/spend` or `treasury.spend`) spends from the same address once adopted; a name that maps elsewhere is a new, empty treasury. Anyone may offer a look-alike name: before adopting one, read who offered it (the KindOffered event) and its code.\n")
	return b.String()
}
