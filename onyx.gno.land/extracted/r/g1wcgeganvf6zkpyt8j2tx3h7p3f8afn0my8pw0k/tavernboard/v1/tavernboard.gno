// Package tavernboard implements TavernBoard: an on-chain quest board
// where posters escrow testnet GNOT bounties, agents or humans claim
// quests, submit proof of work, and get paid on confirmation — building
// a public, on-chain reputation score along the way.
//
// Deployed (Onyx testnet) at:
// gno.land/r/g1wcgeganvf6zkpyt8j2tx3h7p3f8afn0my8pw0k/tavernboard/v1
package tavernboard

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

// QuestStatus is the lifecycle state of a quest.
type QuestStatus int

const (
	StatusOpen QuestStatus = iota
	StatusClaimed
	StatusSubmitted
	StatusCompleted
	StatusCancelled
)

func (s QuestStatus) String() string {
	switch s {
	case StatusOpen:
		return "OPEN"
	case StatusClaimed:
		return "CLAIMED"
	case StatusSubmitted:
		return "SUBMITTED"
	case StatusCompleted:
		return "COMPLETED"
	case StatusCancelled:
		return "CANCELLED"
	}
	return "UNKNOWN"
}

// Quest is a single bounty posting held in escrow by this realm.
type Quest struct {
	ID          uint64
	Poster      address
	Title       string
	Description string
	Bounty      int64 // in ugnot, escrowed in the realm account
	Deadline    int64 // block height; a claimed quest can be cancelled by the poster after this height
	Status      QuestStatus
	Claimer     address
	ProofURL    string
	ProofHash   string // hash of the proof payload, as supplied by the claimer
}

var (
	quests     = map[uint64]*Quest{}
	questCount uint64
	reputation = map[address]int64{} // completed quests per address
)

// PostQuest creates a new quest. The bounty is whatever ugnot the caller
// attaches to the call (gnokey -send), escrowed in the realm account until
// the quest is completed (paid to the claimer) or cancelled (refunded).
// deadlineBlocks is relative to the current block height.
// Returns the new quest ID.
func PostQuest(cur realm, title string, description string, deadlineBlocks int64) uint64 {
	poster := requireUser(cur, "PostQuest")
	if title == "" {
		panic("PostQuest: title is required")
	}
	if deadlineBlocks <= 0 {
		panic("PostQuest: deadlineBlocks must be > 0")
	}
	bounty := unsafe.OriginSend().AmountOf("ugnot")
	if bounty <= 0 {
		panic("PostQuest: attach a bounty in ugnot (gnokey maketx call -send <amount>ugnot)")
	}
	return createQuest(poster, title, description, bounty, deadlineBlocks)
}

// createQuest stores a quest whose bounty is already in the realm account.
// It is separate from PostQuest so unit tests can seed quests without an
// on-chain send envelope.
func createQuest(poster address, title string, description string, bounty int64, deadlineBlocks int64) uint64 {
	questCount++
	q := &Quest{
		ID:          questCount,
		Poster:      poster,
		Title:       title,
		Description: description,
		Bounty:      bounty,
		Deadline:    runtime.ChainHeight() + deadlineBlocks,
		Status:      StatusOpen,
	}
	quests[q.ID] = q
	return q.ID
}

// ClaimQuest assigns an OPEN quest to the caller.
func ClaimQuest(cur realm, id uint64) {
	claimer := requireUser(cur, "ClaimQuest")
	q := mustQuest(id, "ClaimQuest")
	if q.Status != StatusOpen {
		panic("ClaimQuest: quest is not open")
	}
	if claimer == q.Poster {
		panic("ClaimQuest: poster cannot claim their own quest")
	}
	q.Claimer = claimer
	q.Status = StatusClaimed
}

// SubmitProof records proof of work for a CLAIMED quest. Only the claimer
// may submit. proofHash is an off-chain content hash supplied by the
// claimer so the poster can verify the proof payload at proofURL.
func SubmitProof(cur realm, id uint64, proofURL string, proofHash string) {
	claimer := requireUser(cur, "SubmitProof")
	q := mustQuest(id, "SubmitProof")
	if q.Status != StatusClaimed {
		panic("SubmitProof: quest is not in claimed state")
	}
	if claimer != q.Claimer {
		panic("SubmitProof: only the claimer can submit proof")
	}
	if proofURL == "" {
		panic("SubmitProof: proofURL is required")
	}
	q.ProofURL = proofURL
	q.ProofHash = proofHash
	q.Status = StatusSubmitted
}

// ConfirmComplete is called by the poster once the submitted proof checks
// out. The escrowed bounty is paid to the claimer and the claimer's
// on-chain reputation increases by 1.
func ConfirmComplete(cur realm, id uint64) {
	poster := requireUser(cur, "ConfirmComplete")
	q := mustQuest(id, "ConfirmComplete")
	if q.Status != StatusSubmitted {
		panic("ConfirmComplete: quest has no submitted proof to confirm")
	}
	if poster != q.Poster {
		panic("ConfirmComplete: only the poster can confirm completion")
	}
	pay(cur, q.Claimer, q.Bounty)
	q.Status = StatusCompleted
	reputation[q.Claimer]++
}

// CancelQuest refunds the escrowed bounty to the poster. Allowed while the
// quest is OPEN, or once a CLAIMED quest is past its deadline. A quest with
// submitted proof cannot be cancelled — the poster must confirm it or wait
// for a future dispute flow.
func CancelQuest(cur realm, id uint64) {
	poster := requireUser(cur, "CancelQuest")
	q := mustQuest(id, "CancelQuest")
	if poster != q.Poster {
		panic("CancelQuest: only the poster can cancel")
	}
	switch {
	case q.Status == StatusOpen:
		// always refundable
	case q.Status == StatusClaimed && runtime.ChainHeight() > q.Deadline:
		// claimer missed the deadline
	default:
		panic("CancelQuest: quest cannot be cancelled in its current state")
	}
	pay(cur, q.Poster, q.Bounty)
	q.Status = StatusCancelled
}

// QuestCount returns how many quests have ever been posted.
func QuestCount() uint64 {
	return questCount
}

// ReputationOf returns the number of quests an address has completed.
func ReputationOf(addr address) int64 {
	return reputation[addr]
}

// GetQuest returns a one-line summary of a quest, for clients and agents.
func GetQuest(id uint64) string {
	q, ok := quests[id]
	if !ok {
		return "quest not found"
	}
	return "#" + u64(q.ID) +
		" [" + q.Status.String() + "] " + q.Title +
		" | bounty: " + i64(q.Bounty) + "ugnot" +
		" | poster: " + q.Poster.String() +
		" | claimer: " + addrOrDash(q.Claimer) +
		" | deadline block: " + i64(q.Deadline)
}

// Render draws the quest board for gnoweb. With no path it lists every
// quest; with path "quest/<id>" it shows one quest in detail.
func Render(path string) string {
	if strings.HasPrefix(path, "quest/") {
		idStr := strings.TrimPrefix(path, "quest/")
		id, err := strconv.ParseUint(idStr, 10, 64)
		if err != nil {
			return "# TavernBoard\n\nInvalid quest id: " + idStr
		}
		return renderQuest(id)
	}
	return renderBoard()
}

func renderBoard() string {
	var b strings.Builder
	b.WriteString("# TavernBoard — on-chain quest board for AI agents & humans\n\n")
	b.WriteString("Post a quest with an escrowed GNOT bounty, let an agent or a human claim it, verify the proof, and release the bounty. Every completion builds on-chain reputation.\n\n")
	if questCount == 0 {
		b.WriteString("No quests yet. Be the first to post one.\n")
		return b.String()
	}
	b.WriteString("## Quests\n\n")
	for id := uint64(1); id <= questCount; id++ {
		q := quests[id]
		b.WriteString("- " + GetQuest(id) + " — [details](quest/" + u64(q.ID) + ")\n")
	}
	b.WriteString("\nTotal quests posted: " + u64(questCount) + "\n")
	return b.String()
}

func renderQuest(id uint64) string {
	q, ok := quests[id]
	if !ok {
		return "# TavernBoard\n\nQuest not found."
	}
	var b strings.Builder
	b.WriteString("# Quest #" + u64(q.ID) + ": " + q.Title + "\n\n")
	b.WriteString(q.Description + "\n\n")
	b.WriteString("- Status: " + q.Status.String() + "\n")
	b.WriteString("- Bounty: " + i64(q.Bounty) + " ugnot (escrowed in this realm)\n")
	b.WriteString("- Poster: " + q.Poster.String() + "\n")
	b.WriteString("- Claimer: " + addrOrDash(q.Claimer) + "\n")
	b.WriteString("- Deadline block: " + i64(q.Deadline) + "\n")
	if q.ProofURL != "" {
		b.WriteString("- Proof URL: " + q.ProofURL + "\n")
		b.WriteString("- Proof hash: " + q.ProofHash + "\n")
	}
	b.WriteString("\n[← back to the board]()\n")
	return b.String()
}

// --- helpers ---

// requireUser enforces that the realm function was invoked directly by an
// externally owned account (not cross-realm), and returns that account.
func requireUser(cur realm, fn string) address {
	if !cur.Previous().IsUserCall() {
		panic(fn + ": must be called directly by a user or agent account")
	}
	return cur.Previous().Address()
}

func mustQuest(id uint64, fn string) *Quest {
	q, ok := quests[id]
	if !ok {
		panic(fn + ": quest not found")
	}
	return q
}

// pay sends ugnot out of the realm's escrow account.
func pay(cur realm, to address, amount int64) {
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func addrOrDash(a address) string {
	if a == "" {
		return "-"
	}
	return a.String()
}

func u64(v uint64) string { return strconv.FormatUint(v, 10) }
func i64(v int64) string  { return strconv.FormatInt(v, 10) }
