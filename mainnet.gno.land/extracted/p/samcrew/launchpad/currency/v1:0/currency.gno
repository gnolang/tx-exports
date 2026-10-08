// Package currency moves launchpad payments in native ugnot or any GRC20 token.
//
// Every function takes the calling realm's own cur as rlm, so funds always move
// to or from that realm and never from a realm the caller can name.
package currency

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/samcrew/launchpad/meta/v1"
)

const NativeDenom = "ugnot"

// CollectNative accepts exactly amount ugnot attached by the user who called
// the realm directly, and returns that user. Coins attached to a call that
// reaches the realm through another realm belong to that other realm and are
// refused.
func CollectNative(_ int, rlm realm, amount int64) address {
	if !rlm.IsCurrent() {
		panic("launchpad/currency: rlm is not the current realm")
	}
	prev := rlm.Previous()
	if !prev.IsUserCall() {
		panic("launchpad/currency: native payment must be attached to a direct user call")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != NativeDenom || sent[0].Amount != amount {
		panic("launchpad/currency: attached coins do not match the amount due")
	}
	return prev.Address()
}

// AssertNoCoins refuses coins attached by a user who calls the realm directly:
// they would land in the realm, which keeps no account of them. Coins attached
// to a call that reaches the realm through another realm went to that other
// realm and are its business. The pinned chain also fails a call whose coins
// no code reads; this check does not depend on that.
func AssertNoCoins(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("launchpad/currency: rlm is not the current realm")
	}
	if rlm.Previous().IsUserCall() && len(unsafe.OriginSend()) != 0 {
		panic("launchpad/currency: this call does not accept coins")
	}
}

// A token ledger keys balances by the receiver's text, so a receiver in any
// spelling but the one the chain gives a caller would be paid into a balance
// no caller can reach.
func assertReceiver(to address) {
	if !meta.ValidAddress(to) {
		panic("launchpad/currency: invalid receiver")
	}
}

// PayNative sends amount ugnot from the calling realm.
func PayNative(_ int, rlm realm, to address, amount int64) {
	if !rlm.IsCurrent() {
		panic("launchpad/currency: rlm is not the current realm")
	}
	assertReceiver(to)
	banker.NewBanker(banker.BankerTypeRealmSend, rlm).
		SendCoins(rlm.Address(), to, chain.Coins{{NativeDenom, amount}})
}

// CollectToken pulls amount of tok from the realm's direct caller, who must have
// approved the calling realm, and returns that caller.
func CollectToken(_ int, rlm realm, tok *grc20.Token, amount int64) address {
	if !rlm.IsCurrent() {
		panic("launchpad/currency: rlm is not the current realm")
	}
	AssertNoCoins(0, rlm)
	payer := rlm.Previous().Address()
	if err := tok.RealmTeller(0, rlm).TransferFrom(0, rlm, payer, rlm.Address(), amount); err != nil {
		panic(err.Error())
	}
	return payer
}

// PayToken sends amount of tok from the calling realm's own balance.
func PayToken(_ int, rlm realm, tok *grc20.Token, to address, amount int64) {
	if !rlm.IsCurrent() {
		panic("launchpad/currency: rlm is not the current realm")
	}
	assertReceiver(to)
	if err := tok.RealmTeller(0, rlm).Transfer(0, rlm, to, amount); err != nil {
		panic(err.Error())
	}
}
