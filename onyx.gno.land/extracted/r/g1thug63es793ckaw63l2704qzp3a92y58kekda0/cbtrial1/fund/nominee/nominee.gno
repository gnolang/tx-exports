// Package nominee is Charterbook's nominee: one register entry per
// pseudonymous sub-account, no investor wallet in the fund's register, and
// no compliance outcome on-chain (design note v3, section 2).
//
// TEST DEPLOYMENT: fictional nominee, test tokens without value. Not
// operated by any regulated firm. Unaudited code. Not an offer.
//
// Flow: an investor is screened and approved off-chain and receives a
// sub-account identifier privately. The investor deposits whole lots of
// tUSD here. Once the compliance officer has attested the period's batch,
// the operator places the sub-accounts' orders in the fund. Proceeds come
// back here; every payment to a wallet needs the operator and the fund's
// valuation reviewer.
package nominee

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"

	"gno.land/r/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/fund"
	"gno.land/r/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/tusd"
)

const (
	unit int64 = 1_000_000
	lot  int64 = 10_000 * unit
)

var (
	token    *grc20.Token
	selfPath string
	deployer address
	operator address

	attested       = avl.NewTree() // padded period -> *attestation (latest)
	attestLog      = avl.NewTree() // seq -> *attestation
	payments       = avl.NewTree() // id -> *payment
	trail          = avl.NewTree() // seq -> string
	deposits       int64           // number of deposits received
	depositLots    int64
	paidTotal      int64
	nextPay        int64
	trailSeq       int64
	attestSeq      int64
	recommended    int64           // batches the agent screened
	recommendedFor = avl.NewTree() // padded period -> true: the agent screened that period's batch
)

type attestation struct {
	period     int64
	commitment string
	height     int64
	screened   bool
}

type payment struct {
	id     int64
	period int64 // approval only in the fund period it was proposed in
	to     address
	amount int64
	paid   bool
	closed bool
}

func init(cur realm) {
	token = grc20reg.MustGet(tusd.TokenKey())
	selfPath = cur.PkgPath()
	deployer = cur.Previous().Address()
}

// ConfirmWithFund tells the fund, from this realm's own code, that the
// nominee is deployed at the registered path. Deployer only, before the
// fund's Launch.
func ConfirmWithFund(cur realm) {
	assertMasterKey()
	if cur.Previous().Address() != deployer {
		panic("deployer only")
	}
	fund.ConfirmNominee(cross(cur))
}

// SetOperator names the nominee operator. Deployer only, once, after the
// fund has launched, so the fund's roles are fixed and can be checked
// (review 2, I5).
func SetOperator(cur realm, op address) {
	assertMasterKey()
	if cur.Previous().Address() != deployer {
		panic("deployer only")
	}
	if operator != "" {
		panic("operator already set")
	}
	if !fund.Launched() {
		panic("set the operator after the fund has launched")
	}
	if !op.IsValid() || op == deployer || op == Address() {
		panic("invalid operator address")
	}
	if fund.IsRoleOrFundAccount(op) { // all five roles, the deployer, the fund accounts
		panic("the operator cannot hold a fund role")
	}
	operator = op
	addTrail("deployer", "Nominee operator set.")
}

// Address is the nominee's own account, which holds the pool.
func Address() address { return chain.PackageAddress(selfPath) }

// Balance is the pool: deposits not yet placed, plus proceeds not yet paid.
func Balance() int64 { return tusd.BalanceOf(Address()) }

// ---- investors ----

// Deposit moves `lots` whole lots of tUSD from the caller into the pool.
// First Approve the nominee's address on tUSD. The transaction is public;
// nothing here links the wallet to a sub-account.
func Deposit(cur realm, lots int64) {
	if lots < 1 || lots > 1_000 {
		panic("lots must be 1 to 1,000")
	}
	amount := lots * lot
	w := cur.Previous().Address()
	if w == Address() {
		panic("invalid depositor")
	}
	if _, closedToSubs, windingDown, closed := fund.Status(); closedToSubs || windingDown || closed {
		panic("the fund is not taking subscriptions")
	}
	deposits++
	depositLots += lots
	if err := token.RealmTeller(0, cur).TransferFrom(0, cur, w, Address(), amount); err != nil {
		panic(err.Error())
	}
	addTrail("investor", ufmt.Sprintf("Deposit received: %d lot(s).", lots))
}

// ---- screening agent and compliance officer ----

// RecommendBatch records that the screening agent screened this period's
// batch (salted commitment). Agent session only.
func RecommendBatch(cur realm, period int64, commitment string) {
	fund.CheckAgent(cur.Previous().Address())
	checkHex(commitment)
	n, _ := fund.CurrentPeriod()
	if period != n {
		panic("not the current period")
	}
	recommended++
	recommendedFor.Set(pad(period), true) // kept for the officer's attestation (review 2, I7)
	if v := attested.Get(pad(period)); v != nil {
		v.(*attestation).screened = true
	}
	addTrail("screening agent", ufmt.Sprintf("Batch for period %d screened.", period))
}

// AttestBatch is the compliance officer's statement that every sub-account
// in this period's batch was screened and approved. The commitment is a
// salted SHA-256 of the batch and the list snapshots used. Officer only.
func AttestBatch(cur realm, period int64, commitment string) {
	assertMasterKey()
	_, _, _, off := fund.Roles()
	if cur.Previous().Address() != off {
		panic("compliance officer only")
	}
	checkHex(commitment)
	n, open := fund.CurrentPeriod()
	if period != n || !open {
		panic("the batch must be for the current, open period")
	}
	a := &attestation{period: period, commitment: commitment, height: runtime.ChainHeight(), screened: recommendedFor.Has(pad(period))}
	attested.Set(pad(period), a)
	attestSeq++
	attestLog.Set(pad(attestSeq), a)
	addTrail("compliance", ufmt.Sprintf("Batch for period %d attested: %s.", period, commitment))
}

// ---- operator: orders in the fund ----

func onlyOperator(cur realm) {
	assertMasterKey()
	if operator == "" || cur.Previous().Address() != operator {
		panic("nominee operator only")
	}
}

func requireAttested() {
	n, _ := fund.CurrentPeriod()
	if !attested.Has(pad(n)) {
		panic("no compliance attestation for this period's batch")
	}
}

// PlaceSubscription subscribes amount tUSD from the pool for sub-account
// sub. Needs the officer's attestation for the current period.
func PlaceSubscription(cur realm, sub string, amount int64) int64 {
	onlyOperator(cur)
	checkHex(sub)
	requireAttested()
	if amount <= 0 || amount > Balance() {
		panic("amount must be positive and within the pool")
	}
	tusd.Approve(cross(cur), fund.Address(), amount)
	id := fund.SubscribeFor(cross(cur), sub, amount)
	addTrail("operator", ufmt.Sprintf("Subscription #%d placed in the fund.", id))
	return id
}

// PlaceRedemption asks the fund to redeem `lots` lots (0 = all) for
// sub-account sub. Proceeds come back to the pool. Needs the officer's
// attestation for the current period, like a subscription.
func PlaceRedemption(cur realm, sub string, lots int64) int64 {
	onlyOperator(cur)
	checkHex(sub)
	requireAttested()
	id := fund.RequestRedemptionFor(cross(cur), sub, lots)
	addTrail("operator", ufmt.Sprintf("Redemption request #%d placed in the fund.", id))
	return id
}

// RegisterSubAccount records sub-account `sub` in the fund before its
// identifier is handed to the investor, so the fund can refuse any
// compliance decision naming it. Operator only.
func RegisterSubAccount(cur realm, sub string) {
	onlyOperator(cur)
	checkHex(sub)
	fund.RegisterSubAccountFor(cross(cur), sub)
	addTrail("operator", "A sub-account was registered.")
}

// AskToWithdraw asks the fund to withdraw sub-account sub's open order at
// the investor's request; the fund's administrator then withdraws it.
func AskToWithdraw(cur realm, sub string) {
	onlyOperator(cur)
	checkHex(sub)
	fund.AskToWithdrawFor(cross(cur), sub)
	addTrail("operator", "Withdrawal of an order requested.")
}

// CancelOrder takes sub-account sub's subscription back out of escrow in a
// period the fund has left stalled for 7 days (a safety valve: no
// attestation needed).
func CancelOrder(cur realm, sub string) {
	onlyOperator(cur)
	checkHex(sub)
	fund.CancelFor(cross(cur), sub)
	addTrail("operator", "An order was cancelled.")
}

// ---- payments: operator proposes, the fund's reviewer countersigns ----

// ProposePayment proposes to pay amount tUSD from the pool to wallet `to`:
// redemption proceeds, or a refund of a deposit. Operator only.
func ProposePayment(cur realm, to address, amount int64) int64 {
	onlyOperator(cur)
	if !to.IsValid() || to == Address() {
		panic("invalid recipient")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	nextPay++
	n, _ := fund.CurrentPeriod()
	payments.Set(pad(nextPay), &payment{id: nextPay, period: n, to: to, amount: amount})
	addTrail("operator", ufmt.Sprintf("Payment #%d proposed: %s tUSD.", nextPay, fmtAmt(amount)))
	return nextPay
}

// ApprovePayment countersigns and makes a payment. The fund's valuation
// reviewer only.
func ApprovePayment(cur realm, id int64) {
	assertMasterKey()
	_, _, rev, _ := fund.Roles()
	if cur.Previous().Address() != rev {
		panic("valuation reviewer only")
	}
	p := getPayment(id)
	if p.paid || p.closed {
		panic("payment is closed")
	}
	if n, _ := fund.CurrentPeriod(); n != p.period {
		panic("the payment was proposed in an earlier period; propose it again")
	}
	if p.amount > Balance() {
		panic("the pool does not hold this amount")
	}
	p.paid = true
	paidTotal += p.amount
	tusd.Transfer(cross(cur), p.to, p.amount)
	addTrail("reviewer", ufmt.Sprintf("Payment #%d countersigned and made: %s tUSD.", id, fmtAmt(p.amount)))
}

// CancelPayment withdraws (operator) or declines (reviewer) a payment.
func CancelPayment(cur realm, id int64) {
	assertMasterKey()
	_, _, rev, _ := fund.Roles()
	c := cur.Previous().Address()
	if c != operator && c != rev {
		panic("nominee operator or valuation reviewer only")
	}
	p := getPayment(id)
	if p.paid || p.closed {
		panic("payment is closed")
	}
	p.closed = true
	addTrail("nominee", ufmt.Sprintf("Payment #%d cancelled.", id))
}

func getPayment(id int64) *payment {
	v := payments.Get(pad(id))
	if v == nil {
		panic("unknown payment")
	}
	return v.(*payment)
}

// ---- page ----

const banner = "> **Test deployment on the Onyx testnet.** Fictional nominee, test tokens without value. Not operated by any regulated firm. Unaudited code. Not an offer.\n\n"

// Render shows totals only: no wallet, no sub-account, no payment recipient.
func Render(path string) string {
	parts := strings.Split(path, "/")
	page := 1
	if len(parts) == 2 && parts[0] == "trail" {
		n, err := strconv.Atoi(parts[1])
		if err != nil || n < 1 {
			return "invalid page"
		}
		page = n
	} else if path != "" && path != "trail" {
		return "404"
	}
	var b strings.Builder
	home := strings.TrimPrefix(selfPath, "gno.land")
	fh := strings.TrimPrefix(fund.Path(), "gno.land")
	b.WriteString("# Charterbook nominee\n\n" + banner)
	b.WriteString("[Nominee](" + home + ") · [Nominee trail](" + home + ":trail) · [The fund](" + fh + ")\n\n")
	if parts[0] == "trail" {
		pages := int((trailSeq + 19) / 20)
		if pages == 0 {
			pages = 1
		}
		if page > pages {
			return "invalid page"
		}
		b.WriteString(ufmt.Sprintf("Newest first. Page %d of %d.\n\n| # | Event |\n|---:|---|\n", page, pages))
		trail.ReverseIterateByOffset((page-1)*20, 20, func(k string, v any) bool {
			b.WriteString("| " + strings.TrimLeft(k, "0") + " | " + sanitize.TableCell(v.(string)) + " |\n")
			return false
		})
		if page < pages {
			b.WriteString(ufmt.Sprintf("\n[Older](%s:trail/%d)", home, page+1))
		}
		return b.String()
	}
	accounts, shares := fund.NomineeTotals()
	b.WriteString("Investors hold fund shares here through pseudonymous sub-accounts. The fund applies all its rules to each sub-account. No investor wallet appears in the fund's register and no compliance outcome is published. Deposits and payments between wallets and this nominee are public; privacy grows with the number of investors per period. Investors trust the operator and the fund's reviewer to pay the right wallet, as with a custodian.\n\n")
	b.WriteString(ufmt.Sprintf("- Pool: %s tUSD (deposits not yet placed, and proceeds not yet paid)\n", fmtAmt(Balance())))
	b.WriteString(ufmt.Sprintf("- Sub-accounts holding shares: %d · shares: %s\n", accounts, fmtAmt(shares)))
	b.WriteString(ufmt.Sprintf("- Deposits received: %d (%d lots) · payments made: %s tUSD\n", deposits, depositLots, fmtAmt(paidTotal)))
	b.WriteString("- Operator: " + addrOr(operator) + "\n\n")
	b.WriteString("## Compliance attestations\n\nEach is the compliance officer's statement that every sub-account in that period's batch was screened against the public sanctions lists and approved. The commitment covers the batch and the list snapshots used.\n\n| Period | Commitment | Agent screening on file | Height |\n|---:|---|---|---:|\n")
	attestLog.ReverseIterateByOffset(0, 12, func(_ string, v any) bool {
		a := v.(*attestation)
		scr := "no"
		if a.screened {
			scr = "yes"
		}
		b.WriteString(ufmt.Sprintf("| %d | `%s` | %s | %d |\n", a.period, a.commitment, scr, a.height))
		return false
	})
	b.WriteString("\n## Deposit\n\nApprove this nominee's address `" + Address().String() + "` on Test Dollar, then [deposit one lot](" + home + "$help&func=Deposit&lots=1).\n")
	return b.String()
}

// ---- helpers ----

func assertMasterKey() {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("master key required: session keys are refused")
	}
}

func addTrail(role, text string) {
	trailSeq++
	trail.Set(pad(trailSeq), role+": "+text)
	chain.Emit("CharterbookNominee", "role", role, "text", text)
}

func checkHex(c string) {
	if len(c) != 64 {
		panic("identifier must be a 64-character hex SHA-256")
	}
	for _, r := range c {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			panic("identifier must be lowercase hex")
		}
	}
}

func pad(n int64) string {
	s := ufmt.Sprintf("%d", n)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func fmtAmt(v int64) string {
	f := ufmt.Sprintf("%d", v%unit)
	for len(f) < 6 {
		f = "0" + f
	}
	return ufmt.Sprintf("%d", v/unit) + "." + f
}

func addrOr(a address) string {
	if a == "" {
		return "not set"
	}
	return "`" + a.String() + "`"
}
