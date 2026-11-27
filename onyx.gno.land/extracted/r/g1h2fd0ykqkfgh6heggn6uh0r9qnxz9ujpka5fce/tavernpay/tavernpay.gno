// Package tavernpay implements TavernPay: recurring payment mandates on Gno.land.
//
// A payer locks an escrow of amount*maxPayments ugnot and names a payee.
// Anyone (a keeper) can execute a payment once it is due by block height;
// the realm pays `amount` ugnot from escrow to the payee. The payer can
// cancel at any time and get the remaining escrow refunded.
//
// Security notes (see gno AGENTS.md / gno-security-guide):
//   - Caller identity comes from cur.Previous(); no cur.IsCurrent() guard
//     (always true inside a crossing function).
//   - CreateMandate accepts payment via the -send envelope, so it requires
//     cur.Previous().IsUserCall() (NOT IsUser(), which also accepts
//     maketx-run ephemeral realms that could pre-consume the envelope),
//     paired with runtime.AssertOriginCall().
//   - State is mutated before any coin movement (CEI).
//   - Render never echoes user-controlled strings: the only inputs are
//     typed addresses (bech32, safe charset) and integers.
package tavernpay

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
)

// Mandate is one recurring payment agreement.
type Mandate struct {
	ID             int64
	Payer          address
	Payee          address
	Amount         int64 // ugnot per payment
	IntervalBlocks int64 // blocks between payments
	MaxPayments    int64
	PaymentsMade   int64
	NextDueHeight  int64
	Escrow         int64 // ugnot still locked
	Active         bool
}

var (
	mandates []Mandate
	nextID   int64 = 1
)

// CreateMandate opens a mandate. The caller must attach exactly
// amount*maxPayments ugnot via -send; the coins become the escrow.
// Returns the mandate ID.
func CreateMandate(cur realm, payee address, amount, intervalBlocks, maxPayments int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("CreateMandate: only a direct user call can open a mandate")
	}
	runtime.AssertOriginCall()
	deposit := unsafe.OriginSend().AmountOf("ugnot")
	return createMandate(cur.Previous().Address(), payee, amount, intervalBlocks, maxPayments, deposit)
}

// ExecuteMandate pays one due installment to the payee. Anyone may call
// it (keeper model): the realm itself enforces due-ness, so no trusted
// scheduler is needed.
func ExecuteMandate(cur realm, id int64) {
	idx := findMandateIndex(id)
	if idx < 0 {
		panic("ExecuteMandate: unknown mandate")
	}
	applyPayment(idx, runtime.ChainHeight())
	m := mandates[idx]
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), m.Payee, chain.Coins{{Denom: "ugnot", Amount: m.Amount}})
}

// CancelMandate closes a mandate and refunds the remaining escrow to the
// payer. Only the payer can cancel.
func CancelMandate(cur realm, id int64) {
	if !cur.Previous().IsUserCall() {
		panic("CancelMandate: only a direct user call can cancel a mandate")
	}
	idx := findMandateIndex(id)
	if idx < 0 {
		panic("CancelMandate: unknown mandate")
	}
	refund := applyCancel(idx, cur.Previous().Address())
	if refund > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), mandates[idx].Payer, chain.Coins{{Denom: "ugnot", Amount: refund}})
	}
}

// GetMandate returns a copy of one mandate by ID.
func GetMandate(id int64) Mandate {
	idx := findMandateIndex(id)
	if idx < 0 {
		panic("GetMandate: unknown mandate")
	}
	return mandates[idx]
}

// ListMandates returns a copy of all mandates, newest last.
func ListMandates() []Mandate {
	out := make([]Mandate, len(mandates))
	copy(out, mandates)
	return out
}

// MandateCount returns how many mandates exist.
func MandateCount() int64 {
	return int64(len(mandates))
}

// RealmBalance returns the realm's current ugnot balance.
func RealmBalance() int64 {
	return banker.NewReadonlyBanker().GetCoin(unsafe.CurrentRealm().Address(), "ugnot")
}

// Render shows a Markdown dashboard of all mandates.
func Render(path string) string {
	out := "# TavernPay — recurring payment mandates\n\n"
	out += "Pay once, get paid on schedule. A payer locks amount x maxPayments ugnot; "
	out += "any keeper can execute a due installment; the payer can cancel anytime for a refund.\n\n"
	out += "Realm balance: " + strconv.FormatInt(RealmBalance(), 10) + " ugnot\n\n"
	if len(mandates) == 0 {
		out += "_No mandates yet._\n"
		return out
	}
	out += "| ID | Payer | Payee | Amount | Paid | Next due (height) | Escrow | Active |\n"
	out += "|---:|---|---|---:|---:|---:|---:|:---:|\n"
	for _, m := range mandates {
		out += "|" + strconv.FormatInt(m.ID, 10)
		out += "|" + m.Payer.String()
		out += "|" + m.Payee.String()
		out += "|" + strconv.FormatInt(m.Amount, 10)
		out += "|" + strconv.FormatInt(m.PaymentsMade, 10) + "/" + strconv.FormatInt(m.MaxPayments, 10)
		out += "|" + strconv.FormatInt(m.NextDueHeight, 10)
		out += "|" + strconv.FormatInt(m.Escrow, 10)
		if m.Active {
			out += "|yes|\n"
		} else {
			out += "|no|\n"
		}
	}
	return out
}

// createMandate validates inputs and appends a mandate. Pure state logic
// (no coin movement); the crossing wrapper verifies the deposit.
func createMandate(payer, payee address, amount, intervalBlocks, maxPayments, deposit int64) int64 {
	if amount <= 0 {
		panic("CreateMandate: amount must be positive")
	}
	if intervalBlocks <= 0 {
		panic("CreateMandate: intervalBlocks must be positive")
	}
	if maxPayments <= 0 {
		panic("CreateMandate: maxPayments must be positive")
	}
	if deposit != amount*maxPayments {
		panic("CreateMandate: attached ugnot must equal amount*maxPayments")
	}
	m := Mandate{
		ID:             nextID,
		Payer:          payer,
		Payee:          payee,
		Amount:         amount,
		IntervalBlocks: intervalBlocks,
		MaxPayments:    maxPayments,
		PaymentsMade:   0,
		NextDueHeight:  runtime.ChainHeight() + intervalBlocks,
		Escrow:         deposit,
		Active:         true,
	}
	mandates = append(mandates, m)
	nextID++
	return m.ID
}

// applyPayment advances one installment's state. Panics unless the
// mandate is active, incomplete, and due at the given height.
func applyPayment(idx int, height int64) {
	m := &mandates[idx]
	if !m.Active {
		panic("ExecuteMandate: mandate not active")
	}
	if m.PaymentsMade >= m.MaxPayments {
		panic("ExecuteMandate: mandate complete")
	}
	if height < m.NextDueHeight {
		panic("ExecuteMandate: payment not due yet")
	}
	m.PaymentsMade++
	m.Escrow -= m.Amount
	m.NextDueHeight += m.IntervalBlocks
	if m.PaymentsMade >= m.MaxPayments {
		m.Active = false
	}
}

// applyCancel closes a mandate and returns the refundable escrow.
// Panics unless the caller is the payer and the mandate is active.
func applyCancel(idx int, caller address) int64 {
	m := &mandates[idx]
	if !m.Active {
		panic("CancelMandate: mandate not active")
	}
	if caller != m.Payer {
		panic("CancelMandate: only the payer can cancel")
	}
	refund := m.Escrow
	m.Escrow = 0
	m.Active = false
	return refund
}

// findMandateIndex returns the slice index of a mandate, or -1.
func findMandateIndex(id int64) int {
	for i := range mandates {
		if mandates[i].ID == id {
			return i
		}
	}
	return -1
}
