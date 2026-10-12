package abt

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/grc20/v0"
	"gno.land/r/akkadia/beta/admin"
)

const FrozenChangedEvent = "FrozenChanged"

var (
	// Even a Token can create mutable tellers; keep all capabilities private.
	token  *grc20.Token
	ledger *grc20.PrivateLedger
	frozen = true
)

func init(cur realm) {
	token, ledger = grc20.NewToken("Akkadia Beta Token", "abt", 6, 0, cur)
}

// Mint remains available while frozen. Each successful call issues new tokens.
func Mint(cur realm, to address, amount int64) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoCoins(0, cur)
	if !to.IsValid() {
		panic("invalid abt recipient")
	}
	if amount <= 0 {
		panic("abt amount must be positive")
	}
	if err := ledger.Mint(to, amount); err != nil {
		panic("abt mint failed: " + err.Error())
	}
}

// SetFrozen preserves existing allowances, which become usable after unfreezing.
func SetFrozen(cur realm, value bool) {
	caller := accesscontrol.MustGetAdminCaller(0, cur, admin.IsAdmin)
	assertNoCoins(0, cur)
	if frozen == value {
		return
	}
	previous := frozen
	frozen = value
	chain.Emit(FrozenChangedEvent,
		"executor", caller.String(),
		"previous", strconv.FormatBool(previous),
		"frozen", strconv.FormatBool(frozen),
	)
}

func Transfer(cur realm, to address, amount int64) {
	assertCanTransfer(0, cur)
	if err := ledger.CallerTeller().Transfer(0, cur, to, amount); err != nil {
		panic("abt transfer failed: " + err.Error())
	}
}

// Approve also rejects allowance revocation while frozen.
func Approve(cur realm, spender address, amount int64) {
	assertCanTransfer(0, cur)
	if err := ledger.CallerTeller().Approve(0, cur, spender, amount); err != nil {
		panic("abt approval failed: " + err.Error())
	}
}

func TransferFrom(cur realm, from, to address, amount int64) {
	assertCanTransfer(0, cur)
	// The library spends allowance before rejecting self-transfers. Reject
	// here so even a caller that revives the abort cannot consume allowance.
	if from == to {
		panic("abt transfer failed: cannot send transfer to self")
	}
	if err := ledger.CallerTeller().TransferFrom(0, cur, from, to, amount); err != nil {
		panic("abt transfer failed: " + err.Error())
	}
}

func IsFrozen() bool                         { return frozen }
func GetName() string                        { return token.GetName() }
func GetSymbol() string                      { return token.GetSymbol() }
func GetDecimals() int                       { return token.GetDecimals() }
func TotalSupply() int64                     { return token.TotalSupply() }
func BalanceOf(owner address) int64          { return token.BalanceOf(owner) }
func Allowance(owner, spender address) int64 { return token.Allowance(owner, spender) }

func assertCanTransfer(_ int, rlm realm) {
	accesscontrol.AssertCurrentRealm(0, rlm)
	assertNoCoins(0, rlm)
	if frozen {
		panic("abt is frozen")
	}
}

func assertNoCoins(_ int, rlm realm) {
	// OriginSend belongs to the origin call, not a subsequent realm relay.
	if rlm.Previous().IsUser() && len(unsafe.OriginSend()) != 0 {
		panic("attached coins not allowed")
	}
}
