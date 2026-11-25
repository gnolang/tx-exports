// Package trickle is the accounting core of a linear payment stream.
//
// A Stream escrows a fixed Deposit that unlocks linearly between Start and
// End, with an optional Cliff before which nothing is claimable. The package
// holds no coins and reads no clock: every method takes the current unix time
// as an argument, so any realm can embed a Stream and settle it in whatever
// asset it custodies (native coins, GRC20 tokens, points).
//
// Invariant, at every instant and after every operation:
//
//	Withdrawn + Withdrawable(now) + Refundable(now) == Deposit
//
// Typical use from a realm:
//
//	s, err := trickle.New(sender, recipient, amount, start, cliff, end, true)
//	...
//	paid, err := s.Withdraw(now, 0) // 0 = everything claimable
//	toRecipient, toSender, err := s.Cancel(now)
package trickle
