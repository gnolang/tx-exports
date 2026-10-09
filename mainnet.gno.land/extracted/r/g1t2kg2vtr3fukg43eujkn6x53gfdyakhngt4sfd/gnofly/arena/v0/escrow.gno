package arena

import (
	"chain"
	"chain/banker"
)

// The money of the realm goes through the four functions below and nowhere
// else.
//
// escrowed is what the realm owes: the stakes of every lobby and of every
// running round, in ugnot. It goes up in hold, when a player enters, and
// down in release, before coins leave. The balance of the realm's address is
// what it has. The rule of this file is
//
//	balance >= escrowed, and balance == escrowed unless someone gave coins away
//
// Coins can only come in through Enter: the chain refuses a call that
// attaches coins to a function that does not read them. Someone can still
// send coins straight to the realm's address with a bank transfer. Such
// coins are owed to nobody, no function spends them, and they stay there.
//
// Every function that moves money ends with assertSolvent. If a mistake in
// this realm ever made a path send more than it released, the realm would be
// paying one player with the stake of another: the check turns that into an
// aborted transaction, which takes the payments back with it.

// payDenom is the only coin the realm deals in.
const payDenom = "ugnot"

// hold records that the realm received amount in stakes.
func hold(amount int64) {
	if amount <= 0 {
		panic(errEscrow)
	}
	escrowed += amount
}

// release takes amount out of what the realm owes. It is called before the
// coins are sent, and it panics rather than let the counter go below zero.
func release(amount int64) {
	if amount <= 0 || amount > escrowed {
		panic(errEscrow)
	}
	escrowed -= amount
}

// pay sends amount ugnot from the realm's own balance to an address.
//
// A RealmSend banker can spend everything the realm holds, which is why it
// is built here and only here, from the live cur of the crossing function
// (rlm), and never kept. The bank aborts the transaction if the realm does
// not have the coins.
func pay(_ int, rlm realm, to address, amount int64) {
	if amount <= 0 {
		panic(errEscrow)
	}
	coins := chain.NewCoins(chain.NewCoin(payDenom, amount))
	banker.NewBanker(banker.BankerTypeRealmSend, rlm).SendCoins(rlm.Address(), to, coins)
}

// assertSolvent panics unless the realm holds at least what it owes.
func assertSolvent(_ int, rlm realm) {
	if banker.NewReadonlyBanker().GetCoin(rlm.Address(), payDenom) < escrowed {
		panic(errInsolvent)
	}
}

// Escrowed returns what the realm owes to players, in ugnot: the stakes of
// every lobby and of every running round. The balance of the realm's
// address is never below it.
func Escrowed() int64 {
	return escrowed
}
