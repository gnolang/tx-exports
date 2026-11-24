// Package guildhall is the Guildhall bounty board realm. A poster attaches
// GNOT to Post and the realm escrows it until the quest is paid to a worker
// (by Accept or by silence through the review window) or returned to the
// poster (Refund past the deadline, or Cancel while open).
package guildhall

import (
	"strconv"

	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/nym-ololade001/guild/v0"
)

var (
	// quests maps a zero-padded decimal quest id to *guild.Quest. The
	// fixed-width padding keeps AVL iteration in numeric id order.
	quests = avl.NewTree()
	// active holds the same keys for quests that are not in a terminal
	// state, so the board never walks paid, refunded or cancelled rows.
	active = avl.NewTree()
	// profiles maps an address string to *profile.
	profiles = avl.NewTree()

	questSeq seqid.ID

	escrowTotal int64 // ugnot currently locked in live quests
	paidTotal   int64 // ugnot paid out to workers, all time
)

// profile aggregates an address's activity as poster and as worker.
type profile struct {
	Posted       int
	Paid         int
	Accepted     int
	AutoAccepted int
	Earned       int64
	Spent        int64
	PostedIDs    []uint64
	PaidIDs      []uint64
}

// Post escrows the attached ugnot as a quest's reward. The send and the
// direct-user-call check are a pair: OriginSend describes coins that landed
// at this realm only when the caller is a pure EOA, so anything else
// (maketx run scripts, intermediary realms) is rejected first.
func Post(cur realm, title, spec string, leaseBlocks, reviewBlocks, deadline int64) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("Post must be called directly by a user (maketx call)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("attach a positive ugnot reward with -send")
	}
	poster := cur.Previous().Address()
	h := runtime.ChainHeight()
	id := uint64(questSeq.Next())
	q, err := guild.New(id, poster, title, spec, sent[0].Amount, leaseBlocks, reviewBlocks, deadline, h)
	if err != nil {
		panic(err)
	}
	quests.Set(questKey(id), q)
	active.Set(questKey(id), q)
	escrowTotal += q.Reward
	p := getProfile(poster)
	p.Posted++
	p.PostedIDs = append(p.PostedIDs, id)
	chain.Emit("QuestPosted",
		"id", ufmt.Sprintf("%d", id),
		"poster", poster.String(),
		"reward", ufmt.Sprintf("%d", q.Reward))
	return id
}

// Claim lets the caller take an open quest under a fresh lease.
func Claim(cur realm, id uint64) {
	caller := cur.Previous().Address()
	q := mustQuest(id)
	h := runtime.ChainHeight()
	if err := q.Claim(caller, h); err != nil {
		panic(err)
	}
	chain.Emit("QuestClaimed",
		"id", ufmt.Sprintf("%d", id),
		"worker", caller.String(),
		"lease_end", ufmt.Sprintf("%d", q.LeaseEnd))
}

// Submit turns in the caller's proof of work while the lease is live.
func Submit(cur realm, id uint64, proofURL, note string) {
	caller := cur.Previous().Address()
	q := mustQuest(id)
	if err := q.Submit(caller, runtime.ChainHeight(), proofURL, note); err != nil {
		panic(err)
	}
	chain.Emit("QuestSubmitted",
		"id", ufmt.Sprintf("%d", id),
		"worker", caller.String(),
		"proof", proofURL)
}

// Accept pays the escrowed reward to the worker; poster only.
func Accept(cur realm, id uint64) {
	caller := cur.Previous().Address()
	q := mustQuest(id)
	if err := q.Accept(caller, runtime.ChainHeight()); err != nil {
		panic(err)
	}
	payQuest(cur, q)
}

// Reject returns a submitted quest to the board inside the review window;
// poster only.
func Reject(cur realm, id uint64, reason string) {
	caller := cur.Previous().Address()
	q := mustQuest(id)
	if err := q.Reject(caller, runtime.ChainHeight(), reason); err != nil {
		panic(err)
	}
	chain.Emit("QuestRejected",
		"id", ufmt.Sprintf("%d", id),
		"poster", caller.String(),
		"reason", reason)
}

// ClaimPayout pays the worker when the review window closed with no answer
// from the poster; worker only.
func ClaimPayout(cur realm, id uint64) {
	caller := cur.Previous().Address()
	q := mustQuest(id)
	if err := q.AutoAccept(caller, runtime.ChainHeight()); err != nil {
		panic(err)
	}
	payQuest(cur, q)
}

// Refund returns the escrow to the poster once the deadline passed.
func Refund(cur realm, id uint64) {
	caller := cur.Previous().Address()
	q := mustQuest(id)
	if err := q.Refund(caller, runtime.ChainHeight()); err != nil {
		panic(err)
	}
	active.Remove(questKey(id))
	escrowTotal -= q.Reward
	pay(cur, q.Poster, q.Reward)
	chain.Emit("QuestRefunded",
		"id", ufmt.Sprintf("%d", id),
		"poster", caller.String(),
		"amount", ufmt.Sprintf("%d", q.Reward))
}

// Cancel withdraws an open quest and returns its escrow to the poster.
func Cancel(cur realm, id uint64) {
	caller := cur.Previous().Address()
	q := mustQuest(id)
	if err := q.Cancel(caller, runtime.ChainHeight()); err != nil {
		panic(err)
	}
	active.Remove(questKey(id))
	escrowTotal -= q.Reward
	pay(cur, q.Poster, q.Reward)
	chain.Emit("QuestCancelled",
		"id", ufmt.Sprintf("%d", id),
		"poster", caller.String(),
		"amount", ufmt.Sprintf("%d", q.Reward))
}

// payQuest settles a Paid quest: state and totals move before coins do.
func payQuest(cur realm, q *guild.Quest) {
	active.Remove(questKey(q.ID))
	recordPayout(q)
	pay(cur, q.Worker, q.Reward)
	auto := "false"
	if q.AutoPaid {
		auto = "true"
	}
	chain.Emit("QuestPaid",
		"id", ufmt.Sprintf("%d", q.ID),
		"worker", q.Worker.String(),
		"amount", ufmt.Sprintf("%d", q.Reward),
		"auto", auto)
}

// pay sends ugnot out of the realm. The banker is made inside the call and
// never stored: a stored banker would be a permanent spending grant. cur is
// always the caller's live realm value, which is what authorizes the send.
func pay(cur realm, to address, amount int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

func recordPayout(q *guild.Quest) {
	escrowTotal -= q.Reward
	paidTotal += q.Reward
	wp := getProfile(q.Worker)
	wp.Paid++
	wp.Earned += q.Reward
	wp.PaidIDs = append(wp.PaidIDs, q.ID)
	if q.AutoPaid {
		wp.AutoAccepted++
	} else {
		wp.Accepted++
	}
	pp := getProfile(q.Poster)
	pp.Spent += q.Reward
}

func mustQuest(id uint64) *guild.Quest {
	q, ok := quests.Get(questKey(id)).(*guild.Quest)
	if !ok || q == nil {
		panic("quest not found: " + strconv.FormatUint(id, 10))
	}
	return q
}

func getProfile(addr address) *profile {
	key := addr.String()
	if p, ok := profiles.Get(key).(*profile); ok && p != nil {
		return p
	}
	p := &profile{}
	profiles.Set(key, p)
	return p
}

// findProfile reads a profile without creating one, for Render.
func findProfile(addr address) *profile {
	p, _ := profiles.Get(addr.String()).(*profile)
	return p
}

// questKey zero-pads the id to a fixed 20 digits so AVL keys iterate in
// numeric order ("2" sorts before "10"). ufmt's width flag is a no-op for
// ints, so the padding is built by hand.
func questKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}
