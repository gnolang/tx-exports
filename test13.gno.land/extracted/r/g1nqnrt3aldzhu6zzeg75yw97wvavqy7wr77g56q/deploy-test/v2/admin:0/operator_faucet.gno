package admin

import (
	"chain"
	"chain/banker"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
)

const (
	SetFaucetTargetAmountEvent = "SetFaucetTargetAmount"
	RequestFaucetEvent         = "RequestFaucet"
	RequestFaucetsEvent        = "RequestFaucets"
	WithdrawEvent              = "Withdraw"
)

var (
	faucetTargetAmount int64
)

func SetFaucetTargetAmount(cur realm, amount int64) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	assertPositiveFaucetTarget(amount)

	oldAmount := faucetTargetAmount
	faucetTargetAmount = amount

	chain.Emit(
		SetFaucetTargetAmountEvent,
		"oldAmount", int64ToString(oldAmount),
		"newAmount", int64ToString(amount),
	)
}

func GetFaucetTargetAmount() int64 {
	assertMigrationStateAvailable()
	return faucetTargetAmount
}

func RequestFaucet(cur realm) int64 {
	assertNotFrozen()
	caller := mustGetFaucetCaller(0, cur)
	assertPositiveFaucetTarget(faucetTargetAmount)

	return sendFaucetDeficit(cur, caller, true)
}

func RequestFaucetFor(cur realm, operator address) int64 {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	assertPositiveFaucetTarget(faucetTargetAmount)
	assertFaucetOperator(operator)

	return sendFaucetDeficit(cur, operator, true)
}

func RequestFaucets(cur realm) int64 {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	assertPositiveFaucetTarget(faucetTargetAmount)

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	operators := GetOperators()
	deficitOperators := []address{}
	deficits := []int64{}
	totalAmount := int64(0)

	for _, operator := range operators {
		deficit := getFaucetDeficit(bnk, operator)
		if deficit <= 0 {
			continue
		}

		deficitOperators = append(deficitOperators, operator)
		deficits = append(deficits, deficit)
		totalAmount += deficit
	}

	if totalAmount == 0 {
		return 0
	}

	assertAdminRealmBalance(bnk, cur.Address(), totalAmount)
	for i, operator := range deficitOperators {
		sendAdminRealmUgnot(bnk, cur.Address(), operator, deficits[i])
		emitRequestFaucet(operator, deficits[i])
	}

	chain.Emit(
		RequestFaucetsEvent,
		"amount", int64ToString(totalAmount),
		"targetAmount", int64ToString(faucetTargetAmount),
	)

	return totalAmount
}

func Withdraw(cur realm, recipient address, amount int64) int64 {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	assertValidAddress(recipient)
	assertPositiveUgnotAmount(amount)

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	assertAdminRealmBalance(bnk, realmAddr, amount)
	sendAdminRealmUgnot(bnk, realmAddr, recipient, amount)

	chain.Emit(
		WithdrawEvent,
		"recipient", recipient.String(),
		"amount", int64ToString(amount),
	)

	return amount
}

func sendFaucetDeficit(cur realm, operator address, panicIfFunded bool) int64 {
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	amount := getFaucetDeficit(bnk, operator)
	if amount <= 0 {
		if panicIfFunded {
			panic("operator balance is not below faucet target")
		}
		return 0
	}

	realmAddr := cur.Address()
	assertAdminRealmBalance(bnk, realmAddr, amount)
	sendAdminRealmUgnot(bnk, realmAddr, operator, amount)
	emitRequestFaucet(operator, amount)

	return amount
}

func getFaucetDeficit(bnk banker.Banker, operator address) int64 {
	operatorBalance := bnk.GetCoins(operator).AmountOf("ugnot")
	if operatorBalance >= faucetTargetAmount {
		return 0
	}

	return faucetTargetAmount - operatorBalance
}

func assertAdminRealmBalance(bnk banker.Banker, realmAddr address, amount int64) {
	realmBalance := bnk.GetCoins(realmAddr).AmountOf("ugnot")
	if realmBalance < amount {
		panic("admin realm balance is insufficient")
	}
}

func sendAdminRealmUgnot(bnk banker.Banker, realmAddr address, recipient address, amount int64) {
	coins := chain.Coins{chain.Coin{"ugnot", amount}}
	bnk.SendCoins(realmAddr, recipient, coins)
}

func emitRequestFaucet(operator address, amount int64) {
	chain.Emit(
		RequestFaucetEvent,
		"operator", operator.String(),
		"amount", int64ToString(amount),
		"targetAmount", int64ToString(faucetTargetAmount),
	)
}

func mustGetFaucetCaller(_ int, rlm realm) address {
	caller := accesscontrol.MustGetUserCaller(0, rlm)
	assertFaucetOperator(caller)
	return caller
}

func assertFaucetOperator(operator address) {
	assertValidAddress(operator)
	if !IsOperator(operator) {
		panic("operator access required")
	}
}
