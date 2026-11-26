// Package kite settles Kite payments. Each transfer is paid into its own
// sub-realm address, derived from the transfer before anything is on-chain.
package kite

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/gnoswap/router"
	"gno.land/r/nt/grc20reg/v0"

	k "gno.land/p/g14czcnuxrsl9erkuwzh406rc73629rg7swqymqs/kite"
)

const (
	Open     = "Open"
	Settled  = "Settled"
	Refunded = "Refunded"
)

type record struct {
	transfer k.Transfer
	status   string
	amount   int64
	height   int64
}

var (
	realmPath string
	admin     address
	operators avl.Tree
	closed    avl.Tree
	recent    []string
)

func init(cur realm) {
	realmPath = cur.PkgPath()
	// The namespace is the deployer's address.
	admin = address(strings.Split(realmPath, "/")[2])
	if !admin.IsValid() {
		panic("kite: deploy under an address namespace")
	}
}

func Settle(cur realm, transfer string) {
	assertOperator(cur)
	t, hash := mustOpen(transfer)
	if time.Now().Unix() > t.ExpiresAt {
		panic("kite: Expired")
	}

	sub := cur.Sub(t.Subpath())
	balance := balanceOf(t.Token, sub.Address())
	if balance < t.Amount {
		panic("kite: InsufficientPayment")
	}

	if excess := balance - t.Amount; excess > 0 {
		send(0, sub, t.Token, t.Refund, excess)
		chain.Emit("ExcessRefunded", "transfer_id", t.ID, "deposit", sub.Address().String(), "token", t.Token, "to", t.Refund.String(), "amount", itoa(excess))
	}
	out := t.Amount
	if t.Settle != t.Token {
		out = swap(0, sub, t)
	}
	for i, f := range t.Fees {
		send(0, sub, t.Settle, f.Recipient, f.Amount)
		chain.Emit("FeePaid", "transfer_id", t.ID, "deposit", sub.Address().String(), "index", itoa(int64(i)), "to", f.Recipient.String(), "amount", itoa(f.Amount))
	}
	payout := out - t.TotalFees()
	if payout > 0 {
		send(0, sub, t.Settle, t.Recipient, payout)
	}

	markClosed(hash, t, Settled, payout)
	chain.Emit("Settled", "transfer_id", t.ID, "deposit", sub.Address().String(), "to", t.Recipient.String(), "amount", itoa(payout))
}

// swap trades exactly t.Amount through GnoSwap as the deposit, and returns what
// arrived, measured on the deposit's balance rather than taken from the router.
func swap(_ int, sub realm, t k.Transfer) int64 {
	dep := sub.Address()
	before := balanceOf(t.Settle, dep)
	grc20reg.Approve(0, sub, t.Token, chain.PackageAddress("gno.land/r/gnoswap/router"), t.Amount)
	router.ExactInSwapRoute(cross(sub), t.Token, t.Settle, itoa(t.Amount), t.Route, "100", itoa(t.MinOut), t.ExpiresAt, "")
	out := balanceOf(t.Settle, dep) - before
	if out < t.MinOut {
		panic("kite: SlippageExceeded")
	}
	chain.Emit("Swapped", "transfer_id", t.ID, "deposit", dep.String(), "token", t.Token, "amount_in", itoa(t.Amount), "settle", t.Settle, "amount_out", itoa(out))
	return out
}

// Refund returns the deposit to the refund address. Before expiry only an operator can call it, after it anyone can.
func Refund(cur realm, transfer string) {
	t, hash := mustOpen(transfer)
	if !IsOperator(cur.Previous().Address()) && time.Now().Unix() <= t.ExpiresAt {
		panic("kite: NotExpired")
	}

	sub := cur.Sub(t.Subpath())
	balance := balanceOf(t.Token, sub.Address())
	if balance == 0 {
		panic("kite: NothingToRefund")
	}
	send(0, sub, t.Token, t.Refund, balance)

	markClosed(hash, t, Refunded, balance)
	chain.Emit("Refunded", "transfer_id", t.ID, "deposit", sub.Address().String(), "to", t.Refund.String(), "amount", itoa(balance))
}

// Recover sends a token left in a deposit to destination, or the refund address when it's empty.
func Recover(cur realm, transfer, token, destination string) {
	assertOperator(cur)
	t := mustDecode(transfer)
	if token == t.Token && Status(transfer) == Open {
		panic("kite: RecoveryNotAllowed")
	}
	if !k.IsToken(token) {
		panic("kite: invalid token")
	}
	to := t.Refund
	if destination != "" {
		to = address(destination)
		if !to.IsValid() {
			panic("kite: invalid destination")
		}
	}

	sub := cur.Sub(t.Subpath())
	balance := balanceOf(token, sub.Address())
	if balance == 0 {
		panic("kite: NothingToRecover")
	}
	send(0, sub, token, to, balance)
	chain.Emit("Recovered", "transfer_id", t.ID, "deposit", sub.Address().String(), "token", token, "to", to.String(), "amount", itoa(balance))
}

func Status(transfer string) string {
	return StatusOf(mustDecode(transfer).Hash())
}

func StatusOf(hash string) string {
	if r := closed.Get(hash); r != nil {
		return r.(*record).status
	}
	return Open
}

func DepositAddress(transfer string) address {
	return mustDecode(transfer).DepositAddress(realmPath)
}

func Admin() address { return admin }

func IsOperator(addr address) bool { return operators.Has(addr.String()) }

func GrantOperator(cur realm, operator address) {
	assertAdmin(cur)
	if !operator.IsValid() {
		panic("kite: invalid operator")
	}
	operators.Set(operator.String(), true)
	chain.Emit("OperatorGranted", "operator", operator.String())
}

func RevokeOperator(cur realm, operator address) {
	assertAdmin(cur)
	operators.Remove(operator.String())
	chain.Emit("OperatorRevoked", "operator", operator.String())
}

func SetAdmin(cur realm, newAdmin address) {
	assertAdmin(cur)
	if !newAdmin.IsValid() {
		panic("kite: invalid admin")
	}
	admin = newAdmin
	chain.Emit("AdminSet", "admin", newAdmin.String())
}

func Render(path string) string {
	if strings.HasPrefix(path, "t/") {
		return renderTransfer(strings.TrimPrefix(path, "t/"))
	}

	var sb strings.Builder
	sb.WriteString("# Kite\n\nEach Kite payment is paid into its own address, derived from the transfer. Kite's operator settles it to the merchant, with fees, or refunds it. After expiry anyone can refund it.\n\n")
	sb.WriteString(ufmt.Sprintf("- Admin: %s\n- Operators: %d\n- Closed transfers: %d\n\n", admin.String(), operators.Size(), closed.Size()))
	if len(recent) > 0 {
		sb.WriteString("## Recent\n\n| Transfer | Status | Token | Amount |\n|---|---|---|---|\n")
		for i := len(recent) - 1; i >= 0; i-- {
			r := closed.Get(recent[i]).(*record)
			sb.WriteString(ufmt.Sprintf("| [%s](:t/%s) | %s | %s | %d |\n", r.transfer.ID, recent[i], r.status, r.token(), r.amount))
		}
	}
	return sb.String()
}

func renderTransfer(hash string) string {
	deposit := chain.DerivePkgSubAddr(realmPath, k.Subpath(hash))
	r := closed.Get(hash)
	if r == nil {
		gnot := banker.NewReadonlyBanker().GetCoin(deposit, k.Native)
		return ufmt.Sprintf("# Transfer\n\n- Status: Open, or not a Kite transfer\n- Deposit address: %s\n- Holds: %d ugnot\n", deposit.String(), gnot)
	}
	rec := r.(*record)
	t := rec.transfer
	return ufmt.Sprintf("# Transfer %s\n\n- Status: %s at block %d\n- Deposit address: %s\n- Paid: %d %s\n- Settles in: %s\n- Merchant: %s\n- Fees: %d\n- Refund address: %s\n- Expires: %s\n- Sent: %d %s\n",
		t.ID, rec.status, rec.height, deposit.String(), t.Amount, t.Token, t.Settle, t.Recipient.String(), t.TotalFees(), t.Refund.String(),
		time.Unix(t.ExpiresAt, 0).UTC().Format(time.RFC3339), rec.amount, rec.token())
}

// a settled transfer pays out in its settlement token; a refund returns the token paid
func (r *record) token() string {
	if r.status == Settled {
		return r.transfer.Settle
	}
	return r.transfer.Token
}

func markClosed(hash string, t k.Transfer, status string, amount int64) {
	closed.Set(hash, &record{t, status, amount, runtime.ChainHeight()})
	recent = append(recent, hash)
	if len(recent) > 20 {
		recent = recent[1:]
	}
}

func balanceOf(token string, addr address) int64 {
	if token == k.Native {
		return banker.NewReadonlyBanker().GetCoin(addr, k.Native)
	}
	return grc20reg.MustGet(token).BalanceOf(addr)
}

func send(_ int, sub realm, token string, to address, amount int64) {
	if token == k.Native {
		banker.NewBanker(banker.BankerTypeRealmSend, sub).SendCoins(sub.Address(), to, chain.Coins{{k.Native, amount}})
		return
	}
	grc20reg.Transfer(0, sub, token, to, amount)
}

func mustDecode(transfer string) k.Transfer {
	t, err := k.Decode(transfer)
	if err != nil {
		panic("kite: InvalidTransfer: " + err.Error())
	}
	return t
}

func mustOpen(transfer string) (k.Transfer, string) {
	t := mustDecode(transfer)
	hash := t.Hash()
	if closed.Has(hash) {
		panic("kite: NotOpen")
	}
	return t, hash
}

func assertOperator(cur realm) {
	if !IsOperator(cur.Previous().Address()) {
		panic("kite: NotOperator")
	}
}

func assertAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("kite: NotAdmin")
	}
}

func itoa(n int64) string { return ufmt.Sprintf("%d", n) }
