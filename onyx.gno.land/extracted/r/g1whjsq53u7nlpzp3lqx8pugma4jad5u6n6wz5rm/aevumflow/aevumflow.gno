package aevumflow

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"time"
)

// AevumFlow — trustless invoice escrow for Gno.land.
//
// Lifecycle:
//   1. Issuer calls CreateInvoice(amount, memo, deliverInSec)  -> StatusCreated
//   2. Payer calls Fund(id) attaching exactly `amount` ugnot    -> StatusFunded
//      (coins land in the realm balance via the tx `send` envelope)
//   3. After delivery, Settle(id) releases escrow to the issuer
//      minus a protocol fee (feeBps basis points)               -> StatusSettled
//   4. If the issuer never delivers, anyone may Refund(id)
//      after deliverBy and the payer gets everything back       -> StatusRefunded
//
// Every state transition is enforced on-chain; the escrowed coins can
// only leave the realm through Settle or Refund.

const (
	StatusCreated uint8 = iota
	StatusFunded
	StatusSettled
	StatusRefunded
)

const (
	FeeBps    int64 = 100 // 1% protocol fee, taken at settlement
	MaxMemoLn int   = 140
)

var (
	invoices []*Invoice // id -> invoice (ids are dense, 1-based)
	nextID   uint64
)

type Invoice struct {
	ID        uint64
	Issuer    address
	Payer     address
	Amount    int64     // ugnot attached to Fund()
	Memo      string
	CreatedAt time.Time // block timestamp at creation
	DeliverBy time.Time // refundable after this
	Status    uint8
}

// --- lifecycle ---------------------------------------------------------

// CreateInvoice opens a new invoice. The caller becomes the issuer.
// deliverInSec is how long the payer has before the escrow becomes refundable.
func CreateInvoice(cur realm, amount int64, memo string, deliverInSec int64) uint64 {
	if amount <= 0 {
		panic("amount must be > 0")
	}
	if len(memo) > MaxMemoLn {
		panic("memo too long")
	}
	if deliverInSec <= 0 {
		panic("deliverInSec must be > 0")
	}
	issuer := cur.Previous().Address()
	now := time.Now()
	nextID++
	inv := &Invoice{
		ID:        nextID,
		Issuer:    issuer,
		Amount:    amount,
		Memo:      memo,
		CreatedAt: now,
		DeliverBy: now.Add(time.Duration(deliverInSec) * time.Second),
		Status:    StatusCreated,
	}
	invoices = append(invoices, inv)
	return inv.ID
}

// Fund escrows the payment. The caller must attach exactly inv.Amount ugnot
// through the transaction's send envelope.
func Fund(cur realm, id uint64) {
	inv := mustGet(id)
	if inv.Status != StatusCreated {
		panic("invoice not open for funding")
	}
	if !time.Now().Before(inv.DeliverBy) {
		panic("invoice expired")
	}
	if !cur.Previous().IsUserCall() {
		panic("only user-call accepted")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != inv.Amount {
		panic("must attach exactly " + i64str(inv.Amount) + "ugnot")
	}
	inv.Payer = cur.Previous().Address()
	inv.Status = StatusFunded
}

// Settle releases the escrow to the issuer. Allowed once the invoice is
// Funded; before deliverBy only the issuer may settle, after deliverBy
// anyone may finalize (trustless completion).
func Settle(cur realm, id uint64) {
	inv := mustGet(id)
	if inv.Status != StatusFunded {
		panic("invoice is not funded")
	}
	caller := cur.Previous().Address()
	now := time.Now()
	if now.Before(inv.DeliverBy) && caller != inv.Issuer {
		panic("only the issuer can settle before the deadline")
	}
	fee := inv.Amount * FeeBps / 10000
	payout := inv.Amount - fee
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	b.SendCoins(realmAddr, inv.Issuer, chain.Coins{chain.NewCoin("ugnot", payout)})
	inv.Status = StatusSettled
}

// Refund returns the escrowed coins to the payer. Only callable after
// deliverBy on a funded, unsettled invoice.
func Refund(cur realm, id uint64) {
	inv := mustGet(id)
	if inv.Status != StatusFunded {
		panic("invoice is not funded")
	}
	if time.Now().Before(inv.DeliverBy) {
		panic("deadline not reached")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), inv.Payer, chain.Coins{chain.NewCoin("ugnot", inv.Amount)})
	inv.Status = StatusRefunded
}

// --- views -------------------------------------------------------------

func GetInvoice(id uint64) *Invoice {
	return mustGet(id)
}

func InvoiceCount() uint64 {
	return nextID
}

// FeeFor returns the protocol fee (in ugnot) that would be taken when
// settling an invoice of `amount`.
func FeeFor(amount int64) int64 {
	return amount * FeeBps / 10000
}

// --- render ------------------------------------------------------------

func statusName(s uint8) string {
	switch s {
	case StatusCreated:
		return "Created"
	case StatusFunded:
		return "Funded"
	case StatusSettled:
		return "Settled"
	case StatusRefunded:
		return "Refunded"
	}
	return "?"
}

func Render(path string) string {
	out := "# AevumFlow — invoice escrow\n\n"
	out += "Trustless invoice escrow: issuer creates, payer funds with an attached ugnot send, settle releases to the issuer (1% fee), refund returns escrow after the deadline.\n\n"
	out += "| id | amount | status | memo |\n|---|---|---|---|\n"
	for _, inv := range invoices {
		out += "| " + u64str(inv.ID) + " | " + i64str(inv.Amount) + "ugnot | " + statusName(inv.Status) + " | " + memoCell(inv.Memo) + " |\n"
	}
	if len(invoices) == 0 {
		out += "(no invoices yet)\n"
	}
	if path != "" {
		out += "\n(detailed view not implemented for path: " + path + ")\n"
	}
	return out
}

// --- helpers -----------------------------------------------------------

func mustGet(id uint64) *Invoice {
	if id == 0 || id > nextID {
		panic("invoice not found")
	}
	return invoices[id-1]
}

func memoCell(m string) string {
	// escape pipe chars for the markdown table
	out := make([]rune, 0, len(m))
	for _, r := range m {
		if r == '|' {
			out = append(out, '/')
		} else {
			out = append(out, r)
		}
	}
	return string(out)
}

func u64str(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

func i64str(v int64) string {
	if v == 0 {
		return "0"
	}
	if v < 0 {
		return "-" + u64str(uint64(-v))
	}
	return u64str(uint64(v))
}
