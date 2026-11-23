// Package questmaster is a GNOT bounty board. A poster locks GNOT on a quest,
// a builder takes it and submits a link to the work, and the poster approves
// (paying the builder) or rejects (reopening the quest). If the poster stays
// silent past the review window (about 7 days), the builder can claim the
// payout. A poster can cancel an open quest for a refund, or close a claimed
// or submitted one: the builder keeps their turn, and if it ends without
// approval the reward goes back to the poster.
//
// The rules live in the pure package p/escrow. This realm stores quests,
// holds the coins and moves them only as an escrow move tells it to.
//
// Callers (v1): every state-changing function accepts only a direct user call
// (`gnokey maketx call`, i.e. cur.Previous().IsUserCall()). Calls from other
// realms and from `maketx run` scripts are refused. This is what makes the
// unsafe.OriginSend() checks sound: for a direct user call, the coins sent with
// the call are guaranteed to have landed in this realm. Realm or DAO callers
// may be supported in a later version.
//
// There is no admin, owner, pause, upgrade or sweep function. Nobody can move
// escrowed coins except through the quest moves below.
//
// Coins sent straight to the realm address with a bank send (not through
// PostQuest) are not tracked by any quest and cannot be moved by anyone, so
// they are lost. On chain the guarantee is therefore: realm balance >= the
// locked total, with equality when nobody sends coins outside PostQuest. The
// pages and GetTotals use only the tracked numbers, never the balance.
//
// Nothing here hands out a pointer to stored state: read functions return
// plain values (QuestView, Totals, []uint64, strings).
package questmaster

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/escrow"
	"gno.land/p/nt/avl/v0"
)

const (
	// Denom is the only coin a quest reward can be paid in.
	Denom = "ugnot"
	// MinReward is the smallest reward a quest can lock: 1 GNOT.
	MinReward int64 = 1_000_000
	// MaxPageSize caps how many ids one list call returns.
	MaxPageSize = 50
)

// Panic messages for the realm's own checks. Escrow rule violations panic
// with the escrow error's text (prefix "escrow: ").
const (
	ErrNotUserCall   = "questmaster: only direct user calls (gnokey maketx call) are accepted"
	ErrNoCoins       = "questmaster: send the reward in ugnot with the call"
	ErrSeveralCoins  = "questmaster: send exactly one coin (ugnot)"
	ErrWrongDenom    = "questmaster: the reward must be in ugnot"
	ErrRewardTooLow  = "questmaster: the reward is below the minimum of 1 GNOT (1000000ugnot)"
	ErrCoinsNotTaken = "questmaster: this function does not take coins; send none"
	ErrUnknownQuest  = "questmaster: unknown quest id"
)

var (
	quests    avl.Tree // questKey(id) -> *escrow.Quest
	byPoster  avl.Tree // poster address -> *avl.Tree of questKey(id) -> true
	byBuilder avl.Tree // builder address -> *avl.Tree of questKey(id) -> true
	openIDs   avl.Tree // questKey(id) -> true, quests in state Open
	paidIDs   avl.Tree // questKey(id) -> true, quests in state Paid

	lastID uint64

	totalPosted   int64 // ugnot ever locked by PostQuest
	totalLocked   int64 // ugnot held for quests that are Open, Claimed or Submitted
	totalPaid     int64 // ugnot paid to builders
	totalRefunded int64 // ugnot refunded to posters
)

// ---------------------------------------------------------------------------
// State-changing functions

// PostQuest creates a quest. Send the reward with the call as exactly one coin
// of ugnot, at least MinReward. workBlocks is the builder's work window in
// blocks (escrow.MinWorkBlocks to escrow.MaxWorkBlocks). Returns the new id.
func PostQuest(cur realm, title, details string, workBlocks int64) uint64 {
	poster := requireUserCall(cur)
	reward := requireReward()

	id := lastID + 1
	q, err := escrow.NewQuest(id, poster, title, details, reward, workBlocks, runtime.ChainHeight())
	if err != nil {
		panic(err.Error())
	}
	lastID = id
	key := questKey(id)
	quests.Set(key, q)
	addToIndex(&byPoster, poster, key)
	openIDs.Set(key, true)
	totalPosted += reward
	totalLocked += reward

	chain.Emit("QuestPosted", "id", idStr(id), "actor", poster.String(), "amount", amountStr(reward))
	return id
}

// ClaimQuest takes an Open quest. The poster cannot claim their own quest.
func ClaimQuest(cur realm, id uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	q := mustGet(id)
	check(q.Claim(actor, runtime.ChainHeight()))

	key := questKey(id)
	openIDs.Remove(key)
	addToIndex(&byBuilder, actor, key)

	chain.Emit("QuestClaimed", "id", idStr(id), "actor", actor.String())
}

// UnclaimQuest lets the builder give a Claimed quest back. It opens again, or,
// if the poster closed it, ends with a refund to the poster.
func UnclaimQuest(cur realm, id uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	q := mustGet(id)
	p, err := q.Unclaim(actor, runtime.ChainHeight())
	check(err)

	chain.Emit("QuestUnclaimed", "id", idStr(id), "actor", actor.String())
	endTurn(id, p, actor, "unclaimed", cur)
}

// ReleaseQuest ends the builder's turn on a Claimed quest whose work deadline
// has passed. Anyone may call it. The quest opens again, or, if the poster
// closed it, ends with a refund to the poster.
func ReleaseQuest(cur realm, id uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	q := mustGet(id)
	p, err := q.Release(actor, runtime.ChainHeight())
	check(err)

	chain.Emit("QuestReleased", "id", idStr(id), "actor", actor.String())
	endTurn(id, p, actor, "released", cur)
}

// SubmitWork sends the link to the work (must start with https://). Only the
// builder, up to and including the work deadline block.
func SubmitWork(cur realm, id uint64, link string) {
	actor := requireUserCall(cur)
	requireNoCoins()
	q := mustGet(id)
	check(q.Submit(actor, link, runtime.ChainHeight()))

	chain.Emit("WorkSubmitted", "id", idStr(id), "actor", actor.String())
}

// ApproveWork accepts the submitted work and pays the reward to the builder.
// Only the poster.
func ApproveWork(cur realm, id uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	q := mustGet(id)
	p, err := q.Approve(actor, runtime.ChainHeight())
	check(err)

	settlePaid(id, p)
	chain.Emit("QuestPaid", "id", idStr(id), "actor", actor.String(), "to", p.To.String(), "amount", amountStr(p.Amount), "how", "approved")
	send(p, cur)
}

// RejectWork refuses the submitted work with a reason. Its public reject count
// goes up. The quest opens again, or, if the poster closed it, ends with a
// refund to the poster. Only the poster, up to and including the review
// deadline block.
func RejectWork(cur realm, id uint64, reason string) {
	actor := requireUserCall(cur)
	requireNoCoins()
	q := mustGet(id)
	builder := q.Builder()
	p, err := q.Reject(actor, reason, runtime.ChainHeight())
	check(err)

	chain.Emit("WorkRejected", "id", idStr(id), "actor", actor.String(), "builder", builder.String())
	endTurn(id, p, actor, "rejected", cur)
}

// CancelQuest is the poster's way out. Only the poster.
//   - Open quest: it ends at once and the reward is refunded.
//   - Claimed or Submitted quest: it is marked as closing and no coins move.
//     The builder keeps their turn (submit, approval, timeout payout); when
//     the turn ends without approval (unclaim, release after the work
//     deadline, or reject), the quest ends and the reward goes back to the
//     poster instead of the quest opening again.
func CancelQuest(cur realm, id uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	q := mustGet(id)
	p, err := q.Cancel(actor, runtime.ChainHeight())
	check(err)

	if !p.Due() {
		chain.Emit("QuestClosing", "id", idStr(id), "actor", actor.String())
		return
	}
	openIDs.Remove(questKey(id))
	settleRefund(id, p, actor, "open", cur)
}

// endTurn finishes Unclaim, Release and Reject: the quest opens again, or a
// closing quest ends with the refund p.
func endTurn(id uint64, p escrow.Payout, actor address, how string, rlm realm) {
	if !p.Due() {
		openIDs.Set(questKey(id), true)
		return
	}
	settleRefund(id, p, actor, how, rlm)
}

// settleRefund updates totals, emits QuestCancelled and sends the refund
// last. The quest is already Cancelled (final) when it is called.
func settleRefund(id uint64, p escrow.Payout, actor address, how string, rlm realm) {
	if p.Kind != escrow.RefundPoster {
		panic("questmaster: internal error: unexpected payout kind")
	}
	totalLocked -= p.Amount
	totalRefunded += p.Amount
	chain.Emit("QuestCancelled", "id", idStr(id), "actor", actor.String(), "to", p.To.String(), "amount", amountStr(p.Amount), "how", how)
	send(p, rlm)
}

// ClaimPayout pays the builder when the poster has not answered within the
// review window. Only the builder, from the block after the review deadline.
func ClaimPayout(cur realm, id uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	q := mustGet(id)
	p, err := q.ClaimPayout(actor, runtime.ChainHeight())
	check(err)

	settlePaid(id, p)
	chain.Emit("QuestPaid", "id", idStr(id), "actor", actor.String(), "to", p.To.String(), "amount", amountStr(p.Amount), "how", "timeout")
	send(p, cur)
}

// ---------------------------------------------------------------------------
// Read functions. All return plain values.

// QuestView is a read-only copy of one quest at the current block.
type QuestView struct {
	ID               uint64
	Poster           address
	Title            string
	Details          string
	Reward           int64 // ugnot
	State            escrow.State
	Builder          address
	WorkLink         string
	WorkBlocks       int64
	CreatedAt        int64
	ClaimedAt        int64
	SubmittedAt      int64
	WorkDeadline     int64 // last block to submit; 0 unless Claimed or Submitted
	ReviewDeadline   int64 // last block to reject; 0 unless Submitted
	RejectCount      int
	LastRejectReason string
	Closing          bool // the poster closed it; the reward returns when the builder's turn ends without approval
	CanRelease       bool // ReleaseQuest would succeed now
	CanClaimPayout   bool // the builder could call ClaimPayout now
}

// GetQuest returns a copy of quest id. It panics on an unknown id.
func GetQuest(id uint64) QuestView {
	q := mustGet(id)
	h := runtime.ChainHeight()
	return QuestView{
		ID:               q.ID(),
		Poster:           q.Poster(),
		Title:            q.Title(),
		Details:          q.Details(),
		Reward:           q.Reward(),
		State:            q.State(),
		Builder:          q.Builder(),
		WorkLink:         q.WorkLink(),
		WorkBlocks:       q.WorkBlocks(),
		CreatedAt:        q.CreatedAt(),
		ClaimedAt:        q.ClaimedAt(),
		SubmittedAt:      q.SubmittedAt(),
		WorkDeadline:     q.WorkDeadline(),
		ReviewDeadline:   q.ReviewDeadline(),
		RejectCount:      q.RejectCount(),
		LastRejectReason: q.LastRejectReason(),
		Closing:          q.Closing(),
		CanRelease:       q.CanRelease(h),
		CanClaimPayout:   q.CanClaimPayout(h),
	}
}

// Totals are the board-wide running sums, in ugnot.
type Totals struct {
	Quests     uint64 // quests ever posted
	OpenQuests int    // quests in state Open
	Posted     int64  // ugnot ever locked
	Locked     int64  // ugnot held now for Open, Claimed and Submitted quests
	Paid       int64  // ugnot paid to builders
	Refunded   int64  // ugnot refunded to posters
	PaidQuests int    // quests in state Paid
}

// GetTotals returns the running totals. Posted == Locked + Paid + Refunded.
func GetTotals() Totals {
	return Totals{
		Quests:     lastID,
		OpenQuests: openIDs.Size(),
		Posted:     totalPosted,
		Locked:     totalLocked,
		Paid:       totalPaid,
		Refunded:   totalRefunded,
		PaidQuests: paidIDs.Size(),
	}
}

// OpenQuestIDs lists ids of Open quests, newest first. offset skips that many;
// at most MaxPageSize ids are returned whatever limit is.
func OpenQuestIDs(offset, limit int) []uint64 {
	return page(&openIDs, offset, limit)
}

// PaidQuestIDs lists ids of Paid quests, newest first (by quest id).
func PaidQuestIDs(offset, limit int) []uint64 {
	return page(&paidIDs, offset, limit)
}

// AllQuestIDs lists ids of all quests, newest first.
func AllQuestIDs(offset, limit int) []uint64 {
	return page(&quests, offset, limit)
}

// QuestIDsByPoster lists ids of quests posted by addr, newest first.
func QuestIDsByPoster(addr address, offset, limit int) []uint64 {
	return indexPage(&byPoster, addr, offset, limit)
}

// QuestIDsByBuilder lists ids of quests addr has ever claimed, newest first.
// It is a history: a quest stays listed after the builder unclaims it, is
// released or is rejected, even if someone else builds it later. Use
// GetQuest(id).Builder for the current builder.
func QuestIDsByBuilder(addr address, offset, limit int) []uint64 {
	return indexPage(&byBuilder, addr, offset, limit)
}

// CountByPoster returns how many quests addr has posted.
func CountByPoster(addr address) int { return indexSize(&byPoster, addr) }

// CountByBuilder returns how many quests addr has ever claimed.
func CountByBuilder(addr address) int { return indexSize(&byBuilder, addr) }

// ---------------------------------------------------------------------------
// Internal helpers

// requireUserCall refuses anything but a direct user call and returns the
// caller's address. See the package doc for why.
func requireUserCall(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic(ErrNotUserCall)
	}
	return prev.Address()
}

// requireReward checks the coins sent with PostQuest (rules 1 and 2) and
// returns the amount. Valid only together with requireUserCall.
func requireReward() int64 {
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		panic(ErrNoCoins)
	}
	if len(sent) > 1 {
		panic(ErrSeveralCoins)
	}
	if sent[0].Denom != Denom {
		panic(ErrWrongDenom)
	}
	if sent[0].Amount < MinReward {
		panic(ErrRewardTooLow)
	}
	return sent[0].Amount
}

// requireNoCoins refuses coins sent to a function that does not take any
// (rule 3), so nothing gets stuck in the realm.
func requireNoCoins() {
	if len(unsafe.OriginSend()) != 0 {
		panic(ErrCoinsNotTaken)
	}
}

func mustGet(id uint64) *escrow.Quest {
	v := quests.Get(questKey(id))
	if v == nil {
		panic(ErrUnknownQuest)
	}
	return v.(*escrow.Quest)
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}

// settlePaid updates storage and totals for a PayBuilder payout.
func settlePaid(id uint64, p escrow.Payout) {
	if p.Kind != escrow.PayBuilder {
		panic("questmaster: internal error: unexpected payout kind")
	}
	paidIDs.Set(questKey(id), true)
	totalLocked -= p.Amount
	totalPaid += p.Amount
}

// send moves exactly p.Amount ugnot from this realm to p.To. It is called last,
// after every state change (rule 4), and never sends the realm's balance
// (rule 5).
func send(p escrow.Payout, rlm realm) {
	if p.Amount <= 0 || !p.To.IsValid() {
		panic("questmaster: internal error: invalid payout")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	b.SendCoins(rlm.Address(), p.To, chain.Coins{{Denom: Denom, Amount: p.Amount}})
}

// questKey zero-pads id so the avl order is numeric order.
func questKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func idStr(id uint64) string       { return strconv.FormatUint(id, 10) }
func amountStr(ugnot int64) string { return strconv.FormatInt(ugnot, 10) }

func addToIndex(idx *avl.Tree, addr address, key string) {
	var ids *avl.Tree
	if v := idx.Get(addr.String()); v != nil {
		ids = v.(*avl.Tree)
	} else {
		ids = avl.NewTree()
		idx.Set(addr.String(), ids)
	}
	ids.Set(key, true)
}

func indexSize(idx *avl.Tree, addr address) int {
	v := idx.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(*avl.Tree).Size()
}

func indexPage(idx *avl.Tree, addr address, offset, limit int) []uint64 {
	v := idx.Get(addr.String())
	if v == nil {
		return []uint64{}
	}
	return page(v.(*avl.Tree), offset, limit)
}

// page returns up to min(limit, MaxPageSize) ids from t, newest first.
func page(t *avl.Tree, offset, limit int) []uint64 {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > MaxPageSize {
		limit = MaxPageSize
	}
	ids := []uint64{}
	t.ReverseIterateByOffset(offset, limit, func(key string, _ any) bool {
		id, err := strconv.ParseUint(key, 10, 64)
		if err != nil {
			panic("questmaster: internal error: bad key")
		}
		ids = append(ids, id)
		return false
	})
	return ids
}
