// Package luckydice is a deliberately vulnerable demo dice game realm for
// RealmCheck, the Gno.land audit demo entry for the Gnome Tavern Hackathon.
//
// Players buy chips and bet them on a dice roll. It is intentionally
// insecure: the winning number is derived from public chain data, the
// current block height and the current block time, and it is readable by
// anyone through DrawNumber before betting. Anyone can look up the winning
// number and then bet on it, so the game is perfectly predictable.
//
// Demo only. Chips are modeled as an internal ledger so the realm is
// self-contained and testable offline with `gno test`. Do not use this code
// for a real game.
package luckydice

import (
	"errors"
	"strconv"
	"time"

	"chain/runtime"
	"chain/runtime/unsafe"
)

// Game constants.
const (
	// BetCost is the chip cost of one bet.
	BetCost int64 = 100
	// Payout is what a winning bet pays, including the stake.
	Payout int64 = 500
	// Faces is the number of faces on the dice.
	Faces int64 = 6
)

// chips holds the chip balance of each player.
var chips = map[address]int64{}

// gamesPlayed counts resolved bets.
var gamesPlayed int64

// totalWagered counts chips staked in resolved bets.
var totalWagered int64

// totalPaid counts chips paid out to winners.
var totalPaid int64

// BuyChips credits amount chips to the caller.
//
// INTENTIONAL VULNERABILITY (demo): funds accepted without a check. This
// function reads the coins actually sent with the transaction through
// unsafe.OriginSend(), then ignores them and credits the claimed chip
// amount instead. It never compares the sent amount with the claimed
// amount. Any caller can claim chips of any size while sending nothing,
// or sending far less, and the game will treat the invented chips as real
// funds. A safe version would credit chips only for the amount actually
// sent.
func BuyChips(cur realm, amount int64) {
	caller := cur.Previous().Address()
	if amount <= 0 {
		panic("chip amount must be positive")
	}
	sent := unsafe.OriginSend()
	_ = sent // the sent coins are read and then never checked
	chips[caller] += amount
}

// DrawNumberAt computes the winning number from a block height and a block
// time. It is a pure helper so the formula can be tested exactly.
func DrawNumberAt(height int64, unixTime int64) int {
	return int((height*31 + unixTime) % Faces)
}

// DrawNumber returns the winning number for the current block.
//
// INTENTIONAL VULNERABILITY (demo): weak randomness. The result is derived
// from runtime.ChainHeight() and time.Now().Unix(), which is the block
// time. Both values are public before the bet is placed: the height of the
// next block is known, and the block time is predictable within seconds, so
// any caller can compute the winning number in advance, or simply read it
// here, and then bet on it. Block height and block time are not secret and
// must never seed a game of chance. A safe version would use a commit and
// reveal scheme, a verifiable random function, or an oracle that reveals
// the result only after bets close.
func DrawNumber() int {
	return DrawNumberAt(runtime.ChainHeight(), time.Now().Unix())
}

// PlaceBet stakes BetCost chips on guess. It returns true when the bet wins
// and pays Payout chips to the caller.
//
// Because DrawNumber is public, a caller that bets the number DrawNumber
// returns wins whenever the block height and block time do not change
// between reading the number and placing the bet, which in practice is
// almost always.
func PlaceBet(cur realm, guess int) (bool, error) {
	caller := cur.Previous().Address()
	if guess < 0 || guess >= int(Faces) {
		return false, errors.New("guess must be between 0 and 5")
	}
	if chips[caller] < BetCost {
		return false, errors.New("insufficient chips")
	}
	chips[caller] -= BetCost
	totalWagered += BetCost
	gamesPlayed++
	if guess == DrawNumber() {
		chips[caller] += Payout
		totalPaid += Payout
		return true, nil
	}
	return false, nil
}

// ChipsOf returns the chip balance of addr.
func ChipsOf(addr address) int64 {
	return chips[addr]
}

// GamesPlayed returns the number of resolved bets.
func GamesPlayed() int64 {
	return gamesPlayed
}

// TotalWagered returns the total chips staked so far.
func TotalWagered() int64 {
	return totalWagered
}

// TotalPaid returns the total chips paid out to winners so far.
func TotalPaid() int64 {
	return totalPaid
}

// Render returns a short human readable summary of the game.
func Render(path string) string {
	return "# Lucky Dice\n\n" +
		"Demo dice game for RealmCheck. The draw is public, do not bet on it.\n\n" +
		"Games played: " + strconv.FormatInt(gamesPlayed, 10) + "\n" +
		"Next winning number: " + strconv.Itoa(DrawNumber()) + "\n"
}
