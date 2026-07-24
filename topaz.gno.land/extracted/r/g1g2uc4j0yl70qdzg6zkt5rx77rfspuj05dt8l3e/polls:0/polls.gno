// Package polls implements a single fixed-choice poll where each address
// may cast one vote.
package polls

import (
	"strconv"

	"gno.land/p/nt/avl/v0"
)

type option struct {
	text  string
	votes int
}

var (
	question string
	options  []*option
	voters   avl.Tree // address string -> struct{}
)

func init() {
	question = "What's your favorite gno.land feature?"
	for _, text := range []string{
		"Realms (on-chain smart contracts in Go-like Gno)",
		"GRC20 tokens",
		"Render() — realms rendering their own web pages",
		"The gnokey CLI",
	} {
		options = append(options, &option{text: text})
	}
}

// Vote casts a vote for the option at index i. Each address may vote once.
// EOA-only — MsgRun callers are rejected.
func Vote(cur realm, i int) {
	if !cur.Previous().IsUserCall() {
		panic("only a direct EOA call may vote")
	}
	if i < 0 || i >= len(options) {
		panic("invalid option index")
	}
	addr := cur.Previous().Address().String()
	if voters.Has(addr) {
		panic("this address already voted")
	}
	options[i].votes++
	voters.Set(addr, struct{}{})
}

// Render shows the poll question, options, and current vote tally.
func Render(path string) string {
	out := "# " + question + "\n\n"
	for i, o := range options {
		out += strconv.Itoa(i) + ". " + o.text + " — " + strconv.Itoa(o.votes) + " votes\n"
	}
	out += "\nCall Vote(i) with your option's index to vote.\n"
	return out
}
