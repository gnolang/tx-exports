package raffle

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/commitreveal"
)

type RaffleStatus int

const (
	StatusOpen RaffleStatus = iota
	StatusCommitted
	StatusRevealed
	StatusClosed
)

func (s RaffleStatus) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusCommitted:
		return "committed"
	case StatusRevealed:
		return "revealed"
	case StatusClosed:
		return "closed"
	default:
		return "unknown"
	}
}

type Entry struct {
	Index  int64
	Player address
}

var (
	admin        address
	ticketPrice  int64
	entries      []Entry
	entriesByIdx *avl.Tree // index string -> *Entry (for quick winner lookup)
	status       RaffleStatus
	commitment   []byte
	winner       address
	pot          int64
	round        commitreveal.Round
)

func init() {
	admin = address("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")
	ticketPrice = 1000000 // 1 gnot per ticket
	entries = []Entry{}
	entriesByIdx = avl.NewTree()
	status = StatusOpen
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("raffle: must be a direct user call")
	}
	return cur.Previous().Address()
}

// Enter buys a ticket for the current raffle round.
func Enter(cur realm) {
	caller := assertUserCall(cur)
	if status != StatusOpen {
		panic("raffle: entries are closed for this round")
	}
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount != ticketPrice {
		panic("raffle: must send exact ticket price")
	}

	idx := int64(len(entries))
	e := Entry{Index: idx, Player: caller}
	entries = append(entries, e)
	entriesByIdx.Set(ufmt.Sprintf("%020d", idx), &e)
	pot += amount
}

// CommitWinnerSeed lets admin commit to a random seed before revealing the winner.
// This prevents the admin from picking a favorable seed after seeing entries.
func CommitWinnerSeed(cur realm, commitHash []byte) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("raffle: admin only")
	}
	if status != StatusOpen {
		panic("raffle: raffle not open")
	}
	if len(entries) == 0 {
		panic("raffle: no entries yet")
	}
	commitment = commitHash
	status = StatusCommitted
	round = commitreveal.NewRound(runtime.ChainHeight(), 1, 100)
}

// RevealAndDraw reveals the seed, verifies it against the commitment, and
// draws the winner deterministically from entries.
func RevealAndDraw(cur realm, salt []byte, seed []byte) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("raffle: admin only")
	}
	if status != StatusCommitted {
		panic("raffle: not in committed state")
	}
	if !commitreveal.VerifyReveal(commitment, salt, seed) {
		panic("raffle: reveal does not match commitment")
	}

	h := sha256.Sum256(seed)
	// Use the hash bytes as a big-endian number mod len(entries).
	var acc uint64
	for _, b := range h[:8] {
		acc = (acc << 8) | uint64(b)
	}
	winIdx := int64(acc % uint64(len(entries)))

	raw := entriesByIdx.Get(ufmt.Sprintf("%020d", winIdx))
	winnerEntry := raw.(*Entry)
	winner = winnerEntry.Player
	status = StatusRevealed
}

// PayoutWinner sends the pot to the drawn winner.
func PayoutWinner(cur realm) {
	assertUserCall(cur)
	if status != StatusRevealed {
		panic("raffle: winner not drawn yet")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := bk.GetCoins(realmAddr).AmountOf("ugnot")
	amount := pot
	if amount > have {
		amount = have
	}
	if amount <= 0 {
		panic("raffle: nothing to pay out")
	}
	bk.SendCoins(realmAddr, winner, chain.Coins{chain.NewCoin("ugnot", amount)})

	status = StatusClosed
}

// StartNewRound resets state for a fresh raffle after payout.
func StartNewRound(cur realm) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("raffle: admin only")
	}
	if status != StatusClosed {
		panic("raffle: current round not closed yet")
	}
	entries = []Entry{}
	entriesByIdx = avl.NewTree()
	status = StatusOpen
	commitment = nil
	winner = address("")
	pot = 0
}

func Render(path string) string {
	out := "# Raffle\n\n"
	out += ufmt.Sprintf("Status: %s | Entries: %d | Pot: %d ugnot\n",
		status.String(), len(entries), pot)
	if status == StatusRevealed || status == StatusClosed {
		out += ufmt.Sprintf("Winner: %s\n", winner)
	}
	return out
}
