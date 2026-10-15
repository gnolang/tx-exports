// Package poll is a single yes/no poll. Each address may vote once;
// voting again updates that address's previous choice and adjusts the tally.
package poll

import (
	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const question = "Should we ship it?"

const barWidth = 20

var (
	votes     avl.Tree // address.String() -> bool (their current choice)
	yesCount  int
	noCount   int
	lastVoter address
)

// Vote records the caller's yes/no choice. Re-voting updates the caller's
// previous choice and adjusts the tally accordingly. EOA-only.
func Vote(cur realm, choice bool) {
	if !cur.Previous().IsUserCall() {
		panic("only a direct wallet call (MsgCall) may vote")
	}
	addr := cur.Previous().Address()
	key := addr.String()

	if prev, ok := votes.Get(key); ok {
		if prev.(bool) {
			yesCount--
		} else {
			noCount--
		}
	}

	votes.Set(key, choice)
	if choice {
		yesCount++
	} else {
		noCount++
	}
	lastVoter = addr

	chain.Emit("Voted", "address", key, "choice", ufmt.Sprintf("%t", choice))
}

func bar() string {
	total := yesCount + noCount
	if total == 0 {
		out := ""
		for i := 0; i < barWidth; i++ {
			out += "⬛"
		}
		return out
	}

	yesBlocks := yesCount * barWidth / total
	noBlocks := barWidth - yesBlocks

	out := ""
	for i := 0; i < yesBlocks; i++ {
		out += "🟩"
	}
	for i := 0; i < noBlocks; i++ {
		out += "🟥"
	}
	return out
}

func Render(_ string) string {
	out := "# " + question + "\n\n"
	out += bar() + "\n\n"
	out += ufmt.Sprintf("Yes: %d  |  No: %d\n\n", yesCount, noCount)

	if yesCount+noCount == 0 {
		out += "No votes yet.\n"
	} else {
		out += ufmt.Sprintf("Last voter: %s\n", lastVoter.String())
	}
	return out
}
