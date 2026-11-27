// Package vulnmint is a deliberately vulnerable demo token realm for
// RealmCheck, the Gno.land audit demo entry for the Gnome Tavern Hackathon.
//
// It is a small GRC20-like token with an internal ledger. It is intentionally
// insecure: anyone can mint any amount of tokens to any address. The mint
// function has no access control at all, so the token supply is whatever any
// caller says it is. Do not use this code for a real token.
//
// Demo only. The ledger models token balances in memory so the realm is
// self-contained and testable offline with `gno test`.
package vulnmint

import (
	"errors"
	"strconv"
)

// Token metadata.
const (
	Name     = "VulnMint Token"
	Symbol   = "VULN"
	Decimals = 6
)

// balances holds the token balance of each address.
var balances = map[address]int64{}

// totalSupply holds the total number of tokens ever minted minus burned.
// There is no burn function in this demo, so it only grows.
var totalSupply int64

// Mint creates amount tokens and credits them to to.
//
// INTENTIONAL VULNERABILITY (demo): unrestricted mint. This function never
// checks who the caller is. There is no owner check, no minter role, no
// allowlist, and no supply cap. Any address can call Mint and create any
// amount of tokens for any address, which makes the token supply meaningless.
// A safe version would require the caller to be an authorized minter, for
// example by checking cur.Previous().Address() against a stored minter, and
// would enforce a supply cap.
func Mint(cur realm, to address, amount int64) {
	if to == "" {
		panic("mint to empty address")
	}
	if amount <= 0 {
		panic("mint amount must be positive")
	}
	balances[to] += amount
	totalSupply += amount
}

// Transfer moves amount tokens from the caller to to.
//
// The caller is the immediate previous realm or user, read from
// cur.Previous().Address(). Unlike Mint, Transfer does check that the sender
// actually holds the tokens, and it returns an error instead of panicking so
// that a calling realm can observe a failed transfer. Callers that ignore the
// returned error are demonstrating the unchecked external call pattern; see
// the adminbackdoor demo realm.
func Transfer(cur realm, to address, amount int64) error {
	from := cur.Previous().Address()
	if to == "" {
		return errors.New("transfer to empty address")
	}
	if amount <= 0 {
		return errors.New("transfer amount must be positive")
	}
	if balances[from] < amount {
		return errors.New("insufficient balance")
	}
	balances[from] -= amount
	balances[to] += amount
	return nil
}

// BalanceOf returns the token balance of addr.
func BalanceOf(addr address) int64 {
	return balances[addr]
}

// TotalSupply returns the total token supply.
func TotalSupply() int64 {
	return totalSupply
}

// Render returns a short human readable summary of the token.
func Render(path string) string {
	return "# " + Name + " (" + Symbol + ")\n\n" +
		"Demo token for RealmCheck. Anyone can mint.\n\n" +
		"Total supply: " + strconv.FormatInt(totalSupply, 10) + "\n"
}
