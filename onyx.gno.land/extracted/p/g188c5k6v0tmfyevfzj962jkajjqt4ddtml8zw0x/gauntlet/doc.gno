// Package gauntlet is a library for coding bounties that are graded by code,
// on-chain, instead of by people.
//
// A Board holds challenges. A challenge is either a set of fixed test cases
// (input -> exact expected output) or a Judge: two functions written by the
// poster, one that generates fresh inputs from a seed and one that checks an
// answer. Judged challenges cannot be gamed with a lookup table, because the
// inputs are only known at the moment of grading.
//
// Solvers compete with a commit-reveal scheme:
//
//  1. Commit: the solver posts sha256(solutionPkgPath + ":" + salt). This fixes
//     their place in the queue before anyone can see their code.
//  2. Deploy: the solver deploys their solution realm.
//  3. Reveal: the solution realm calls the board with the salt and its Solve
//     function. The board recomputes the hash from the caller's package path,
//     grades the function, and records pass or fail.
//
// The winner is the earliest commit that passes. A later commit can never
// overtake an earlier one, so copying someone's deployed code does not pay.
// A commit that is not revealed within the reveal window expires, and its bond
// is added to the reward.
//
// This package moves no coins. It returns Payouts that the hosting realm sends
// with its banker, so any realm can import it and run bounties in any token.
package gauntlet
