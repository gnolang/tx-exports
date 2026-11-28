// Package guard holds the small checks that Assayer's rules ask for.
//
// Every helper panics with a short, stable message when the check fails, so
// a realm can call it as the first line of a function and move on:
//
//	func Withdraw(cur realm, to address, amount int64) {
//		caller := cur.Previous().Address()
//		guard.RequireValidAddr(to, "to")
//		guard.RequirePositive(amount, "amount")
//		balances.Set(caller.String(), guard.SafeSub(balanceOf(caller), amount))
//		...
//	}
//
// Rule → helper:
//
//	AS-S01, AS-S02, AS-S06  OnlyOwner, OnlyOneOf
//	AS-S03                  SafeSub, SafeAdd
//	AS-S09                  RequireValidAddr
//	AS-T02                  RequireMaxLen, RequireNonEmpty
//	AS-T04                  RequireMaxItems
package guard

import "strconv"

// OnlyOwner panics unless caller is owner. owner must be a valid address:
// a zero owner would otherwise lock or open the function by accident.
func OnlyOwner(caller, owner address) {
	if !owner.IsValid() {
		panic("guard: owner is not set")
	}
	if caller != owner {
		panic("guard: caller is not the owner")
	}
}

// OnlyOneOf panics unless caller is one of allowed.
func OnlyOneOf(caller address, allowed ...address) {
	for _, a := range allowed {
		if a.IsValid() && caller == a {
			return
		}
	}
	panic("guard: caller is not authorized")
}

// RequireValidAddr panics if a is not a well-formed bech32 address.
// what names the argument in the error, e.g. "to".
func RequireValidAddr(a address, what string) {
	if !a.IsValid() {
		panic("guard: invalid address for " + what)
	}
}

// RequireMaxLen panics if s is longer than max bytes.
func RequireMaxLen(s string, max int, what string) {
	if len(s) > max {
		panic("guard: " + what + " longer than " + strconv.Itoa(max) + " bytes")
	}
}

// RequireNonEmpty panics if s is empty.
func RequireNonEmpty(s string, what string) {
	if s == "" {
		panic("guard: " + what + " is empty")
	}
}

// RequireMaxItems panics if n (usually len(slice)) is larger than max.
func RequireMaxItems(n, max int, what string) {
	if n > max {
		panic("guard: " + what + " has more than " + strconv.Itoa(max) + " items")
	}
}

// RequirePositive panics unless amount > 0.
func RequirePositive(amount int64, what string) {
	if amount <= 0 {
		panic("guard: " + what + " must be positive")
	}
}

// SafeSub returns balance - amount. It panics if amount is negative or
// larger than balance, so a balance can never go below zero.
func SafeSub(balance, amount int64) int64 {
	if amount < 0 {
		panic("guard: negative amount")
	}
	if amount > balance {
		panic("guard: insufficient balance")
	}
	return balance - amount
}

// SafeAdd returns a + b for non-negative values and panics on overflow.
func SafeAdd(a, b int64) int64 {
	if a < 0 || b < 0 {
		panic("guard: negative operand")
	}
	c := a + b
	if c < a {
		panic("guard: overflow")
	}
	return c
}
