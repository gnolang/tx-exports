// Package mandate is capped, revocable direct debit on native GNOT, built on
// Gno session keys.
//
// A payee publishes a plan ("1 GNOT every 7 days"). A payer subscribes with
// two things signed by the payer's own key:
//
//  1. a session on chain for the payee's collector key, scoped to this realm
//     only, with a spend limit of the plan's amount plus a small fee
//     allowance per period, and an expiry;
//  2. Subscribe here, which records the terms for that session.
//
// The payee's collector then calls Pull once per period, signed with the
// session key on behalf of the payer and sending exactly the plan's amount.
// The realm is the rulebook: it checks who, how much and when, then forwards
// the coins to the payee in the same transaction. It never keeps funds.
//
// Honest limits, also shown on the home page:
//   - It is direct debit, not escrow. A payer can revoke the session, cancel,
//     or empty the account at any time; the payee is then not paid.
//   - The chain caps what the payer can lose per period at the session's
//     spend limit: amount plus fee allowance. A hostile payee can burn the
//     allowance as gas fees (it goes to the network, not to the payee).
//   - The chain allows at most 16 sessions per account, so a wallet can have
//     at most 16 mandates at a time.
//   - A realm cannot see an on-chain session revoke. A service deciding
//     whether someone has paid reads PaidThrough, which moves only when a
//     payment succeeds; HasMandate is only the realm's view (recorded, not
//     cancelled, not expired), and the chain's own view of the session is
//     the free query auth/accounts/<payer>/session/<session address>.
//   - A session scoped to vm/exec:<this realm> also allows every realm under
//     this path (the chain's scope match is prefix-based). Nothing must ever
//     be deployed under a sub-path of this realm. Pull also refuses any
//     session whose allow list is not exactly this realm, but that cannot
//     protect a payer from a sub-realm called directly.
//
// There is no admin, owner, pause, upgrade or sweep.
package mandate

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
)

// Denom is the only coin a plan can be paid in.
const Denom = "ugnot"

// Limits. See docs/design.md for the reasoning behind each value.
const (
	// MinAmount is the smallest plan amount, 0.1 GNOT. A Pull uses about
	// 8-9M gas on a local chain, and the chain charges the whole fee the
	// signer sets, not the gas used: the pages set 20,000 ugnot for 20M gas
	// wanted (Onyx's minimum price of 1 ugnot per 1,000 gas). At 0.1 GNOT that
	// fee is already a fifth of the payment; below it, fees would dominate.
	MinAmount int64 = 100_000
	// MaxAmount is 1,000,000 GNOT per period: far above any real plan, and
	// low enough that totals cannot overflow int64 for millions of pulls.
	MaxAmount int64 = 1_000_000_000_000
	// MinPeriod is one minute: block times are a few seconds, and the
	// chain's spend period is counted in seconds. Short periods exist for
	// demos and tests; pages flag any period under a day.
	MinPeriod int64 = 60
	// MaxPeriod is 30 days, exactly the chain's limit on a session's spend
	// period (tm2 std.MaxSpendPeriod). The session's spend period is always
	// the plan's period, so the cap the pages promise ("at most price +
	// allowance per period") is exactly what the chain enforces. No yearly
	// plans: the chain refuses a session whose spend period is longer.
	MaxPeriod int64 = 30 * 24 * 60 * 60
	// MaxTerm is the longest a mandate may run from the moment it is
	// created: 366 days. A payer renews once a year at most; the chain's own
	// cap on a session's expiry is 4 x 365 days (tm2 std.MaxSessionDuration).
	MaxTerm int64 = 366 * 24 * 60 * 60
	// FeeAllowance is what the pages add to the session's spend limit for
	// fees and storage (0.1 GNOT). The chain accepts a fee when fee / gas
	// wanted is at least the current gas price (1 ugnot per 1,000 gas on
	// Onyx, raised by the chain when blocks are full), and counts the Pull's
	// storage deposit against the same limit. With the pages' 20M gas wanted
	// the minimum fee is 20,000 ugnot. A Pull creates no object: a first
	// payment adds at most 78 bytes measured (7,800 ugnot at 100 ugnot per
	// byte), later ones nothing. So the worst pull costs about 28,000 ugnot
	// and the allowance covers a gas price up to about 4.5x Onyx's current
	// one (docs/design.md, "Pull's budget").
	FeeAllowance int64 = 100_000
	// MaxTitleLen is the longest plan title, in characters.
	MaxTitleLen = 80
	// PageSize is the number of rows per list page and per read call.
	PageSize = 20
	// MaxSessionsPerWallet is the chain's limit (tm2 std.MaxSessionsPerAccount).
	MaxSessionsPerWallet = 16
)

// Plan is published by a payee and never changes. New terms mean a new plan.
type Plan struct {
	ID        uint64
	Payee     address
	Title     string
	Amount    int64 // ugnot per period
	Period    int64 // seconds
	CreatedAt int64 // unix seconds

	Supporters fixedList // every mandate for this plan, oldest first (see encodeEntry)
	Cancelled  int       // how many of them were cancelled
	Pulls      int64     // successful pulls (paid = Pulls * Amount)
	LastPullAt int64     // unix seconds, 0 = never

	// Payments per period window: window k is [k*Period, (k+1)*Period). A
	// mandate pays at most once in a window, and paid time carries over to a
	// payer's next mandate for the plan, so a payer is not charged twice for
	// one period (except when 16 kept periods are already held, see
	// MaxCreditsPerPayer); but these count payments, not distinct people (a creator
	// can pay its own plan from a second wallet). Read with paidWindows, which
	// turns them into counts for the window containing "now" and the one
	// before it, so they are true at any time without a transaction.
	payWindow int64 // index of the window of the last payment
	paidThis  int   // payments in window payWindow
	paidPrev  int   // payments in window payWindow-1

	payee *Payee // direct link, so Pull needs no lookup
}

// Mandate is one payer's permission for one session key on one plan. It
// keeps only what cannot be derived: the amount paid is Pulls * the plan's
// amount, and the last pull was one period before NextPullAt.
type Mandate struct {
	ID         uint64
	Payer      address
	Session    address // address of the session key the payee holds
	CreatedAt  int64
	ExpiresAt  int64 // unix seconds; pulls are refused from this time on
	NextPullAt int64 // unix seconds; the first pull is due at once
	Pulls      int64
	Index      int // position in the plan's supporter list

	CancelledAt int64 // 0 = not cancelled
	CancelledBy address

	plan        *Plan    // direct link, so Pull needs no lookup
	prevOfPayer *Mandate // the payer's previous mandate (history, newest first)
}

// Payee holds a payee's plans, totals and published collector key.
type Payee struct {
	Addr          address
	Plans         int
	planIDs       fixedList // the payee's plan ids, padded (values, not pointers)
	Pulls         int64
	Paid          int64
	LastPullAt    int64
	CollectorKey  string  // bech32 public key (gpub1...), empty if not set
	CollectorAddr address // address derived from CollectorKey by the chain
}

// State. Storage is paid per byte (100 ugnot) and gas mostly per object
// read or written, so the layout keeps both small, and nothing one address
// does can grow what another payer's calls read (docs/design.md):
//   - plans, payees and payers live in avl trees: an attacker can only add
//     depth (log2 of the number of entries);
//   - each payer's lookups live in that payer's own record (Payer, stored
//     by value in the tree), capped at MaxActivePerPayer active mandates
//     and MaxCreditsPerPayer kept credits;
//   - each plan's supporter list holds small values in chunks (see
//     fixedList), so adding one costs the same however long it is;
//   - a payer's history is a linked list through the mandates, walked only
//     by free reads.
var (
	realmPath string // this realm's package path, captured at init

	nextPlanID    uint64
	nextMandateID uint64

	plans  = avl.NewTree() // pad(planID) -> *Plan
	payees = avl.NewTree() // payee -> *Payee
	payers = avl.NewTree() // payer -> Payer (a value, not a pointer)

	totalPulls int64
	totalPaid  int64
)

func init() {
	realmPath = unsafe.CurrentRealm().PkgPath()
}

// Offer publishes a plan: amountUgnot every periodSeconds, paid to the
// caller. Signed with the payee's own key; no session, no coins.
func Offer(cur realm, title string, amountUgnot, periodSeconds int64) uint64 {
	caller := directCaller(cur)
	if err := validateTitle(title); err != "" {
		panic(err)
	}
	if amountUgnot < MinAmount {
		panic("mandate: amount is below the minimum of " + formatUgnot(MinAmount))
	}
	if amountUgnot > MaxAmount {
		panic("mandate: amount is above the maximum of " + formatUgnot(MaxAmount))
	}
	if periodSeconds < MinPeriod {
		panic("mandate: period is below the minimum of " + itoa(MinPeriod) + " seconds")
	}
	if periodSeconds > MaxPeriod {
		panic("mandate: period is above the maximum of " + itoa(MaxPeriod) + " seconds")
	}
	nextPlanID++
	p := &Plan{
		ID:        nextPlanID,
		Payee:     caller,
		Title:     title,
		Amount:    amountUgnot,
		Period:    periodSeconds,
		CreatedAt: time.Now().Unix(),
	}
	pe := payeeOf(caller)
	if pe == nil {
		pe = &Payee{Addr: caller}
		payees.Set(caller.String(), pe)
	}
	p.payee = pe
	plans.Set(pad(p.ID), p)
	pe.Plans++
	pe.planIDs.add(pad(p.ID))
	chain.Emit("PlanOffered",
		"plan", utoa(p.ID),
		"payee", caller.String(),
		"title", p.Title,
		"amount", itoa(p.Amount),
		"period", itoa(p.Period),
	)
	return p.ID
}

// SetCollectorKey publishes the public key (bech32, gpub1...) of the key the
// payee's collector signs pulls with. Plan pages show it in the copy-ready
// commands, so payers create their session for the right key. Signed with
// the payee's own key. It does not change existing mandates.
func SetCollectorKey(cur realm, pubKey string) {
	caller := directCaller(cur)
	if len(pubKey) > 200 || !strings.HasPrefix(pubKey, "gpub1") {
		panic("mandate: collector key must be a bech32 public key starting with gpub1")
	}
	addr, err := chain.PubKeyAddress(pubKey)
	if err != nil || !addr.IsValid() {
		panic("mandate: collector key is not a valid public key")
	}
	if addr == caller {
		panic("mandate: use a dedicated key for collecting, not your main key")
	}
	if collectorFunded(addr) {
		panic("mandate: this key's address " + addr.String() + " has received coins, so it is an account and the chain will refuse every new session for it; make a new key and never send coins to it")
	}
	pe := payeeOf(caller)
	if pe == nil {
		pe = &Payee{Addr: caller}
		payees.Set(caller.String(), pe)
	}
	pe.CollectorKey = pubKey
	pe.CollectorAddr = addr
	chain.Emit("CollectorKeySet", "payee", caller.String(), "pubkey", pubKey, "address", addr.String())
}

// Subscribe records the terms for one session: the payer allows the holder
// of sessionAddr to pull the plan's amount once per period until
// expiresAtUnix, through this realm only. Signed with the payer's own key
// (never a session), no coins. Create the session on chain in the same
// transaction or just before (see the plan page for the exact command).
//
// The first payment is collected by the first Pull, which is due at once
// (billing in advance: each period is paid at its start).
func Subscribe(cur realm, planID uint64, sessionAddr address, expiresAtUnix int64) uint64 {
	payer := directCaller(cur)
	p := planOf(planID)
	if p == nil {
		panic("mandate: no such plan")
	}
	if payer == p.Payee {
		panic("mandate: you cannot subscribe to your own plan")
	}
	if !sessionAddr.IsValid() {
		panic("mandate: invalid session address")
	}
	if sessionAddr == payer || sessionAddr == p.Payee {
		panic("mandate: the session address must be a dedicated session key, not a wallet")
	}
	now := time.Now().Unix()
	if expiresAtUnix <= now {
		panic("mandate: expiry must be in the future")
	}
	if expiresAtUnix > now+MaxTerm {
		panic("mandate: expiry is more than " + itoa(MaxTerm/86400) + " days away")
	}
	pr := payerOf(payer)
	if pr == nil {
		pr = &Payer{}
	}
	// Time already paid for on this plan carries over. Take this plan's
	// credit before pruning, so the prune can never evict the credit about
	// to be used; then take the one the prune may have made from an expired
	// mandate for this plan (at most one of the two exists).
	until := pr.takeCredit(planID, now)
	// An expired mandate's lookups go when its payer subscribes again; the
	// paid time of an expired mandate for this plan comes back directly.
	if u := pr.pruneExpired(payer, planID, now); u > until {
		until = u
	}
	for _, r := range pr.Active {
		if r.Session == sessionAddr {
			panic("mandate: this session already has an active mandate; cancel it first or use another session key")
		}
		if r.PlanID == planID {
			panic("mandate: you already have an active mandate for this plan")
		}
	}
	if len(pr.Active) >= MaxActivePerPayer {
		panic("mandate: at most " + strconv.Itoa(MaxActivePerPayer) + " active mandates per wallet (the chain allows " + strconv.Itoa(MaxSessionsPerWallet) + " sessions); cancel one first")
	}
	// The first pull of the new mandate is due when the paid time ends. The
	// new mandate must outlive it: otherwise it would be listed as paid,
	// expire without ever paying, and hand the credit back, again and again.
	first := now
	carried := int64(0) // paid time carried over: until when, or 0
	status := byte(statusUnpaid)
	if until > now {
		if expiresAtUnix <= until {
			panic("mandate: this plan is already paid for until " + formatTime(until) + " (unix " + itoa(until) + "); choose an expiry after that")
		}
		first, carried = until, until
		status = statusPaid // covered now, so listed as a supporter
	}
	nextMandateID++
	m := &Mandate{
		ID:          nextMandateID,
		Payer:       payer,
		Session:     sessionAddr,
		CreatedAt:   now,
		ExpiresAt:   expiresAtUnix,
		NextPullAt:  first,
		Index:       p.Supporters.N,
		plan:        p,
		prevOfPayer: pr.Head,
	}
	pr.Head = m
	pr.Active = append(pr.Active, activeRef{Session: sessionAddr, PlanID: planID, ID: m.ID, M: m})
	pr.save(payer)
	p.Supporters.add(encodeEntry(payer, m.ID, status))
	chain.Emit("Subscribed",
		"mandate", utoa(m.ID),
		"plan", utoa(planID),
		"payer", payer.String(),
		"payee", p.Payee.String(),
		"session", sessionAddr.String(),
		"expires", itoa(expiresAtUnix),
		"first", itoa(first),
		"carried", itoa(carried),
	)
	return m.ID
}

// Pull collects one period's payment. It must be signed with the mandate's
// session key on behalf of the payer (gnokey ... -master <payer>
// <session key>), as a direct call, sending exactly the plan's amount. The
// realm forwards the coins to the plan's payee in the same transaction.
// At most one pull per period; the next one is due one period after this
// one, the same rule the chain applies to the session's spend period.
func Pull(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("mandate: Pull must be a direct call")
	}
	sess, _, paths, isSession := runtime.GetSessionInfo()
	now := time.Now().Unix()
	m, p := checkPull(isSession, sess, paths, unsafe.OriginCaller(), unsafe.OriginSend(), now)
	recordPull(m, p, now) // state and event first, then the transfer
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), p.Payee, chain.Coins{chain.NewCoin(Denom, p.Amount)})
}

// checkPull applies every rule of Pull to the transaction's session info,
// signer and coins, and returns the mandate and plan to pay, or panics.
// It is separate from Pull so the rules can be unit-tested: `gno test`
// cannot sign with a session key.
func checkPull(isSession bool, sess address, paths []string, payer address, sent chain.Coins, now int64) (*Mandate, *Plan) {
	if !isSession {
		panic("mandate: Pull must be signed with the mandate's session key")
	}
	if len(paths) != 1 || paths[0] != "vm/exec:"+realmPath {
		panic("mandate: the session must be scoped to exactly vm/exec:" + realmPath)
	}
	m := activeBySession(payer, sess)
	if m == nil {
		panic("mandate: no active mandate for this session (never recorded, cancelled or replaced)")
	}
	if now >= m.ExpiresAt {
		panic("mandate: expired")
	}
	if now < m.NextPullAt {
		panic("mandate: too early, next pull from " + itoa(m.NextPullAt))
	}
	p := m.plan
	if len(sent) != 1 || sent[0].Denom != Denom || sent[0].Amount != p.Amount {
		panic("mandate: send exactly " + itoa(p.Amount) + Denom)
	}
	return m, p
}

// recordPull updates the mandate, plan, payee and totals for one payment
// and emits the event. It never creates an object: Pull runs under the
// payer's session budget, which also pays its storage deposit. A first pull
// flips the mandate's entry in the plan's list from unpaid to paid in place
// (same width) and sets fields that were zero (amino omits zero values), a
// few dozen bytes at most; later pulls add nothing.
func recordPull(m *Mandate, p *Plan, now int64) {
	m.NextPullAt = now + p.Period
	if m.Pulls == 0 {
		p.Supporters.setStatus(m.Index, statusPaid)
	}
	m.Pulls++
	p.Pulls++
	p.LastPullAt = now
	p.countPayment(now)
	pe := p.payee
	pe.Pulls++
	pe.Paid += p.Amount
	pe.LastPullAt = now
	totalPulls++
	totalPaid += p.Amount
	chain.Emit("Pulled",
		"mandate", utoa(m.ID),
		"plan", utoa(p.ID),
		"payer", m.Payer.String(),
		"payee", p.Payee.String(),
		"amount", itoa(p.Amount),
		"next", itoa(m.NextPullAt),
	)
}

// Cancel ends a mandate in the realm. The payer or the payee may cancel,
// each with their own key (never a session). A payer should also revoke the
// session on chain (the payer page shows the command); cancelling alone
// already makes every later Pull fail.
func Cancel(cur realm, payer address, sessionAddr address) {
	caller := directCaller(cur)
	m := activeBySession(payer, sessionAddr)
	if m == nil {
		panic("mandate: no active mandate for this payer and session (never recorded, already cancelled or replaced)")
	}
	p := m.plan
	if caller != m.Payer && caller != p.Payee {
		panic("mandate: only the payer or the payee can cancel")
	}
	now := time.Now().Unix()
	pr := payerOf(payer)
	pr.removeActive(m)
	// Paid time stays the payer's. A payee's Cancel never evicts another
	// credit the payer holds: if the record is full, this one is not kept.
	kept := pr.keepCredit(payer, p.ID, m.paidThrough(), now, caller == m.Payer)
	pr.save(payer)
	m.CancelledAt = now
	m.CancelledBy = caller
	p.Cancelled++
	p.Supporters.setStatus(m.Index, statusCancelled)
	chain.Emit("Cancelled",
		"mandate", utoa(m.ID),
		"plan", utoa(p.ID),
		"payer", m.Payer.String(),
		"by", caller.String(),
		"kept", itoa(kept),
	)
}

// countPayment counts one payment at time now in its period window.
func (p *Plan) countPayment(now int64) {
	w := now / p.Period
	switch w {
	case p.payWindow:
		p.paidThis++
	case p.payWindow + 1:
		p.paidPrev, p.paidThis = p.paidThis, 1
	default:
		p.paidPrev, p.paidThis = 0, 1
	}
	p.payWindow = w
}

// paidWindows returns how many payments were made in the period window that
// contains now, and in the window before it.
func (p *Plan) paidWindows(now int64) (current, previous int) {
	switch now / p.Period {
	case p.payWindow:
		return p.paidThis, p.paidPrev
	case p.payWindow + 1:
		return 0, p.paidThis
	}
	return 0, 0
}

// directCaller is the guard shared by every crossing function except Pull:
// a direct call from a user, signed with the user's own key (never a
// session key, or the payee could rewrite terms through the session), with
// no coins attached (the realm never holds funds).
func directCaller(cur realm) address {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("mandate: this function cannot be called with a session key")
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("mandate: direct calls only")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("mandate: do not send coins with this call")
	}
	return prev.Address()
}

func (m *Mandate) isActive(now int64) bool {
	return m.CancelledAt == 0 && now < m.ExpiresAt
}

// paidThrough returns until when this mandate's payments cover its payer:
// its next pull time once it has paid, or when it started with paid time
// carried over from an earlier mandate (its first pull is then after its
// creation). 0 when it has never paid and carried nothing.
func (m *Mandate) paidThrough() int64 {
	if m.Pulls > 0 || m.NextPullAt > m.CreatedAt {
		return m.NextPullAt
	}
	return 0
}

// status is the realm's view of a mandate: cancelled, expired or active.
func (m *Mandate) status(now int64) string {
	switch {
	case m.CancelledAt != 0:
		return "cancelled"
	case now >= m.ExpiresAt:
		return "expired"
	default:
		return "active"
	}
}

func planOf(id uint64) *Plan {
	v := plans.Get(pad(id))
	if v == nil {
		return nil
	}
	return v.(*Plan)
}

func payeeOf(a address) *Payee {
	v := payees.Get(a.String())
	if v == nil {
		return nil
	}
	return v.(*Payee)
}

// validateTitle returns "" or the reason the title is refused: blank, too
// long, not UTF-8, or containing control characters or line separators.
func validateTitle(s string) string {
	if !utf8.ValidString(s) {
		return "mandate: title is not valid UTF-8"
	}
	if strings.TrimSpace(s) == "" {
		return "mandate: title is empty"
	}
	if utf8.RuneCountInString(s) > MaxTitleLen {
		return "mandate: title is longer than " + strconv.Itoa(MaxTitleLen) + " characters"
	}
	for _, r := range s {
		if unicode.IsControl(r) || r == '\u2028' || r == '\u2029' {
			return "mandate: title must be a single line without control characters"
		}
		if unicode.Is(unicode.Cf, r) {
			// format characters: bidi controls (U+202A-U+202E, U+2066-U+2069),
			// zero-width ones (U+200B-U+200F, U+FEFF) and the like, which can make
			// a title display differently from what it says
			return "mandate: title must not contain invisible formatting characters"
		}
	}
	return ""
}

// pad formats an id with a fixed width so tree keys sort numerically.
func pad(id uint64) string {
	s := strconv.FormatUint(id, 10)
	if len(s) < 10 {
		s = strings.Repeat("0", 10-len(s)) + s
	}
	return s
}

func itoa(n int64) string  { return strconv.FormatInt(n, 10) }
func utoa(n uint64) string { return strconv.FormatUint(n, 10) }

// collectorFunded reports whether a collector key's address holds coins.
// Receiving any coin makes an address an account for good, and the chain
// refuses to create a session for a key whose address is an account
// (tm2/pkg/sdk/auth/handler.go:63-65): no new supporter could join. A
// balance cannot see an account that received coins and was emptied; the
// free query auth/accounts/<address> can, and the collector runs it.
func collectorFunded(addr address) bool {
	return len(banker.NewReadonlyBanker().GetCoins(addr)) > 0
}
