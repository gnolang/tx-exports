// Package tavernquests implements Tavern Quests, an on-chain micro-bounty
// board with GNOT escrow, built for the Gnome Tavern hackathon (Gno.land).
//
// A bounty creator locks a GNOT reward in escrow when creating a bounty.
// A worker submits proof of completion. The creator approves the proof and
// the escrow is released to the worker. If the bounty is cancelled before
// any proof is submitted, or the proof is not approved before the deadline,
// the creator can refund the escrow.
//
// Usage (Onyx testnet, chain-id onyx-1):
//
//	// Create a bounty with a 1 GNOT reward (1 GNOT = 1_000_000 ugnot), 7-day deadline:
//	gnokey maketx call -send 1000000ugnot -gas-fee 5000ugnot -gas-wanted 5000000 \
//	  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 \
//	  <key> CreateBounty "Fix README typo" "Fix the typo in section 2" 7
//
//	// Submit proof of work:
//	gnokey maketx call ... <worker-key> SubmitProof 1 "https://github.com/.../pull/3"
//
//	// Creator approves -> escrow pays the worker:
//	gnokey maketx call ... <creator-key> Approve 1
//
//	// Creator refunds (only before submission, or after the deadline):
//	gnokey maketx call ... <creator-key> Refund 1
package tavernquests

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	bounties avl.Tree // id (string) -> *Bounty
	counter  int
)

// CreateBounty creates a new micro-bounty and locks the attached GNOT
// escrow in the realm. The reward is the coins attached to the call
// (-send). deadlineDays <= 0 defaults to 7 days. Returns the bounty ID.
func CreateBounty(cur realm, title, description string, deadlineDays int) int {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	creator := cur.Previous().Address()
	sent := unsafe.OriginSend()
	require(len(sent) != 0, "at least one coin needs to be sent")
	require(len(sent) == 1 && sent[0].Denom == "ugnot", "reward must be a single ugnot amount")
	require(title != "", "title must not be empty")
	if deadlineDays <= 0 {
		deadlineDays = 7
	}
	deadline := time.Now().Add(time.Duration(deadlineDays) * 24 * time.Hour)
	counter++
	id := counter
	bounties.Set(strconv.Itoa(id), newBounty(creator, title, description, sent, deadline))
	return id
}

// SubmitProof submits proof of completion for an open bounty.
// The first submission wins; the creator cannot work on their own bounty.
func SubmitProof(cur realm, id int, proof string) {
	mustGet(id).SubmitProof(0, cur, proof)
}

// Approve approves the submitted proof and releases the escrowed reward
// to the worker. Only the bounty creator can approve.
func Approve(cur realm, id int) {
	mustGet(id).Approve(0, cur)
}

// Refund returns the escrowed reward to the creator. Allowed when the
// bounty was cancelled before any proof was submitted, or when a submitted
// bounty was not approved before its deadline. Never allowed after approval.
func Refund(cur realm, id int) {
	mustGet(id).Refund(0, cur)
}

// BountyCount returns the number of bounties ever created.
func BountyCount() int {
	return counter
}

// GetBounty returns a human-readable summary of one bounty, or "404".
func GetBounty(id int) string {
	b := bounties.Get(strconv.Itoa(id))
	if b == nil {
		return "404"
	}
	return b.(*Bounty).String()
}

// Render returns a list of recent bounties for the homepage, and bounty
// details when specifying a bounty ID.
func Render(path string) string {
	if path == "" { // home
		output := ""
		size := bounties.Size()
		max := 10
		bounties.ReverseIterateByOffset(size-max, max, func(key string, value any) bool {
			b := value.(*Bounty)
			output += ufmt.Sprintf("- %s: %s -(%s)> %s - %s\n",
				key, b.creator, b.reward.String(), b.WorkerOrNone(), b.Status())
			return false
		})
		return output
	}
	// by id
	b := bounties.Get(path)
	if b == nil {
		return "404"
	}
	return b.(*Bounty).String()
}

// pay sends coins from the realm's escrow to the given address.
func pay(cur realm, to address, coins chain.Coins) {
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	banker_.SendCoins(cur.Address(), to, coins)
}

// require checks a condition and panics with a message if it is false.
func require(check bool, msg string) {
	if !check {
		panic(msg)
	}
}

// mustGet retrieves a bounty by its id or panics.
func mustGet(id int) *Bounty {
	b := bounties.Get(strconv.Itoa(id))
	if b == nil {
		panic("unknown bounty ID")
	}
	return b.(*Bounty)
}
