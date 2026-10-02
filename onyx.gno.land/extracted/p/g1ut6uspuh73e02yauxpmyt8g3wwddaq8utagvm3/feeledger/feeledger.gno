// Package feeledger is a pure accounting primitive for realms that hold
// coins on behalf of users and charge an explicit protocol fee on
// deposits. It tracks per-account balances, the sum of user liabilities,
// and a separately-accrued fee pot. It never touches coins itself: the
// importing realm moves coins and drives this ledger, keeping the two in
// lock-step so that
//
//	coins held by realm == UsersTotal() + FeesAccrued() + surplus
//
// where surplus is coins pushed to the realm outside the ledger's flow
// (always >= 0, and 0 if every coin movement goes through the ledger).
//
// Fee model:
//   - Fees are expressed in basis points (1 bps = 0.01%); BpsDenominator
//     is 10000, so bps == 10000 means the whole deposit is fee.
//   - fee = floor(amount * bps / 10000). Rounding always favors the
//     DEPOSITOR: any fractional fee is dropped, the account is credited
//     amount - fee. A small deposit may therefore pay zero fee.
//   - There is no minimum fee. The maximum fee is bounded by the
//     per-ledger cap set at construction (maxFeeBps <= 10000), so a fee
//     can never exceed its deposit.
//   - bps == 0 is a valid configuration: fee is exactly 0 and the full
//     amount is credited.
//
// All failures are returned as errors and leave the ledger COMPLETELY
// UNCHANGED; callers in realms typically wrap calls so an error panics
// and aborts the transaction. Must* wrappers are provided and are the
// only functions in this package that panic.
//
// The ledger is address-agnostic: accounts are non-empty strings. Realms
// normally use address.String().
package feeledger

import (
	"errors"

	"gno.land/p/nt/avl/v0"
)

// BpsDenominator is the fee basis: fees are bps/BpsDenominator of the
// deposited amount.
const BpsDenominator = int64(10000)

// Errors returned by Ledger operations.
var (
	ErrEmptyAccount  = errors.New("feeledger: empty account key")
	ErrInvalidAmount = errors.New("feeledger: amount must be positive")
	ErrInvalidBps    = errors.New("feeledger: fee bps out of range")
	ErrInsufficient  = errors.New("feeledger: insufficient balance")
	ErrOverflow      = errors.New("feeledger: int64 overflow")
)

// Ledger tracks per-account balances, their sum (user liabilities), and
// separately-accrued protocol fees. The zero value is not usable;
// construct with New.
type Ledger struct {
	maxFeeBps   int64
	balances    *avl.Tree // account string -> int64 (always > 0)
	usersTotal  int64     // == sum of all balances
	feesAccrued int64     // fees charged but not yet withdrawn
}

// New returns an empty ledger that rejects deposit fees above maxFeeBps.
// maxFeeBps must be in [0, BpsDenominator].
func New(maxFeeBps int64) (*Ledger, error) {
	if maxFeeBps < 0 || maxFeeBps > BpsDenominator {
		return nil, ErrInvalidBps
	}
	return &Ledger{
		maxFeeBps: maxFeeBps,
		balances:  avl.NewTree(),
	}, nil
}

// MustNew is New but panics on error.
func MustNew(maxFeeBps int64) *Ledger {
	l, err := New(maxFeeBps)
	if err != nil {
		panic(err)
	}
	return l
}

// MaxFeeBps returns the ledger's hard fee cap.
func (l *Ledger) MaxFeeBps() int64 {
	return l.maxFeeBps
}

// FeeFor returns the fee charged on amount at bps, using the ledger's
// rounding rule: floor(amount * bps / BpsDenominator). It is a pure
// preview — no state is read or written beyond validation against
// BpsDenominator (NOT the ledger cap; use it to inspect any policy).
// amount must be >= 0 and bps in [0, BpsDenominator].
func FeeFor(amount, bps int64) (int64, error) {
	if amount < 0 {
		return 0, ErrInvalidAmount
	}
	if bps < 0 || bps > BpsDenominator {
		return 0, ErrInvalidBps
	}
	return feeFor(amount, bps), nil
}

// feeFor computes floor(amount*bps/BpsDenominator) without intermediate
// overflow: amount = q*BpsDenominator + r, so the fee is
// q*bps + floor(r*bps/BpsDenominator). q*bps <= amount because
// bps <= BpsDenominator, and r*bps < BpsDenominator^2 (10^8), so every
// intermediate fits comfortably in int64. Inputs must be pre-validated.
func feeFor(amount, bps int64) int64 {
	q := amount / BpsDenominator
	r := amount % BpsDenominator
	return q*bps + r*bps/BpsDenominator
}

// Deposit credits account with amount minus the fee at feeBps, accruing
// the fee to the fee pot. Returns the credited amount and the fee
// (credited + fee == amount always). Fails with ErrEmptyAccount,
// ErrInvalidAmount (amount <= 0), ErrInvalidBps (feeBps outside
// [0, MaxFeeBps]), or ErrOverflow if the account balance or total
// liabilities would leave int64 range. On error nothing is modified.
func (l *Ledger) Deposit(account string, amount, feeBps int64) (credited, fee int64, err error) {
	if account == "" {
		return 0, 0, ErrEmptyAccount
	}
	if amount <= 0 {
		return 0, 0, ErrInvalidAmount
	}
	if feeBps < 0 || feeBps > l.maxFeeBps {
		return 0, 0, ErrInvalidBps
	}

	fee = feeFor(amount, feeBps)
	credited = amount - fee // >= 0; > 0 whenever feeBps < BpsDenominator

	newBalance, ok := checkedAdd(l.BalanceOf(account), credited)
	if !ok {
		return 0, 0, ErrOverflow
	}
	newUsersTotal, ok := checkedAdd(l.usersTotal, credited)
	if !ok {
		return 0, 0, ErrOverflow
	}
	newFeesAccrued, ok := checkedAdd(l.feesAccrued, fee)
	if !ok {
		return 0, 0, ErrOverflow
	}
	// Total liabilities must stay representable as one int64, since they
	// mirror a single coin balance held by the importing realm.
	if _, ok := checkedAdd(newUsersTotal, newFeesAccrued); !ok {
		return 0, 0, ErrOverflow
	}

	if newBalance > 0 {
		l.balances.Set(account, newBalance)
	}
	l.usersTotal = newUsersTotal
	l.feesAccrued = newFeesAccrued
	return credited, fee, nil
}

// MustDeposit is Deposit but panics on error.
func (l *Ledger) MustDeposit(account string, amount, feeBps int64) (credited, fee int64) {
	credited, fee, err := l.Deposit(account, amount, feeBps)
	if err != nil {
		panic(err)
	}
	return credited, fee
}

// Withdraw debits amount from account. Fails with ErrEmptyAccount,
// ErrInvalidAmount (amount <= 0), or ErrInsufficient if the balance is
// smaller than amount. A balance drained to zero is removed from
// storage. On error nothing is modified.
func (l *Ledger) Withdraw(account string, amount int64) error {
	if account == "" {
		return ErrEmptyAccount
	}
	if amount <= 0 {
		return ErrInvalidAmount
	}
	balance := l.BalanceOf(account)
	if balance < amount {
		return ErrInsufficient
	}
	if balance == amount {
		l.balances.Remove(account)
	} else {
		l.balances.Set(account, balance-amount)
	}
	// usersTotal >= balance >= amount by the sum invariant, so this
	// cannot underflow.
	l.usersTotal -= amount
	return nil
}

// MustWithdraw is Withdraw but panics on error.
func (l *Ledger) MustWithdraw(account string, amount int64) {
	if err := l.Withdraw(account, amount); err != nil {
		panic(err)
	}
}

// WithdrawAll drains account's entire balance and returns it. Returns
// (0, nil) if the account holds nothing. Fails only with
// ErrEmptyAccount.
func (l *Ledger) WithdrawAll(account string) (int64, error) {
	if account == "" {
		return 0, ErrEmptyAccount
	}
	balance := l.BalanceOf(account)
	if balance == 0 {
		return 0, nil
	}
	l.balances.Remove(account)
	l.usersTotal -= balance
	return balance, nil
}

// WithdrawFees drains the accrued fee pot and returns the amount
// (0 if nothing has accrued). Never fails.
func (l *Ledger) WithdrawFees() int64 {
	fees := l.feesAccrued
	l.feesAccrued = 0
	return fees
}

// BalanceOf returns account's balance, or 0 if absent.
func (l *Ledger) BalanceOf(account string) int64 {
	v := l.balances.Get(account)
	if v == nil {
		return 0
	}
	return v.(int64)
}

// UsersTotal returns the sum of all account balances (user liabilities).
func (l *Ledger) UsersTotal() int64 {
	return l.usersTotal
}

// FeesAccrued returns the fee pot: charged but not yet withdrawn.
func (l *Ledger) FeesAccrued() int64 {
	return l.feesAccrued
}

// Liabilities returns UsersTotal() + FeesAccrued() — everything the
// importing realm owes. Deposit guarantees this sum fits in int64.
func (l *Ledger) Liabilities() int64 {
	return l.usersTotal + l.feesAccrued
}

// Accounts returns the number of accounts with a non-zero balance.
func (l *Ledger) Accounts() int {
	return l.balances.Size()
}

// Iterate calls fn for each account in sorted order with its balance.
// Iteration stops early when fn returns true.
func (l *Ledger) Iterate(fn func(account string, balance int64) bool) {
	l.balances.Iterate("", "", func(key string, value any) bool {
		return fn(key, value.(int64))
	})
}

// checkedAdd returns a+b and reports whether the addition did not
// overflow int64.
func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
