package bountyboard

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type Status int

const (
	StatusOpen Status = iota
	StatusClaimed
	StatusSubmitted
	StatusCompleted
	StatusCancelled
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusClaimed:
		return "claimed"
	case StatusSubmitted:
		return "submitted"
	case StatusCompleted:
		return "completed"
	case StatusCancelled:
		return "cancelled"
	default:
		return "unknown"
	}
}

type Bounty struct {
	ID          int64
	Creator     address
	Title       string
	Description string
	Reward      int64 // ugnot, held in escrow by the realm
	Status      Status
	Claimant    address
	SubmissionURL string
	CreatedAt   int64
}

var (
	bounties  *avl.Tree // id (string) -> *Bounty
	nextID    int64
)

func init() {
	bounties = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("bountyboard: must be a direct user call")
	}
	return cur.Previous().Address()
}

func idKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

// CreateBounty opens a new bounty, escrowing the sent ugnot as the reward.
func CreateBounty(cur realm, title string, description string) int64 {
	caller := assertUserCall(cur)
	sent := unsafe.OriginSend()
	reward := sent.AmountOf("ugnot")
	if reward <= 0 {
		panic("bountyboard: must fund bounty with ugnot")
	}
	if title == "" {
		panic("bountyboard: title required")
	}

	id := nextID
	nextID++

	bounties.Set(idKey(id), &Bounty{
		ID:          id,
		Creator:     caller,
		Title:       title,
		Description: description,
		Reward:      reward,
		Status:      StatusOpen,
		CreatedAt:   runtime.ChainHeight(),
	})
	return id
}

func getBounty(id int64) *Bounty {
	key := idKey(id)
	if !bounties.Has(key) {
		panic("bountyboard: bounty not found")
	}
	raw := bounties.Get(key)
	return raw.(*Bounty)
}

// ClaimBounty lets a user claim an open bounty to work on it.
func ClaimBounty(cur realm, id int64) {
	caller := assertUserCall(cur)
	b := getBounty(id)
	if b.Status != StatusOpen {
		panic("bountyboard: bounty is not open")
	}
	b.Status = StatusClaimed
	b.Claimant = caller
}

// SubmitWork lets the claimant submit their work for review.
func SubmitWork(cur realm, id int64, submissionURL string) {
	caller := assertUserCall(cur)
	b := getBounty(id)
	if b.Status != StatusClaimed {
		panic("bountyboard: bounty is not in claimed state")
	}
	if caller != b.Claimant {
		panic("bountyboard: only the claimant can submit work")
	}
	if submissionURL == "" {
		panic("bountyboard: submission URL required")
	}
	b.SubmissionURL = submissionURL
	b.Status = StatusSubmitted
}

// ApproveAndPay lets the bounty creator approve the submission and release escrow.
func ApproveAndPay(cur realm, id int64) {
	caller := assertUserCall(cur)
	b := getBounty(id)
	if b.Status != StatusSubmitted {
		panic("bountyboard: bounty has no pending submission")
	}
	if caller != b.Creator {
		panic("bountyboard: only the creator can approve")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(realmAddr, b.Claimant, chain.Coins{chain.NewCoin("ugnot", b.Reward)})

	b.Status = StatusCompleted
}

// CancelBounty lets the creator cancel an unclaimed bounty and reclaim escrow.
func CancelBounty(cur realm, id int64) {
	caller := assertUserCall(cur)
	b := getBounty(id)
	if b.Status != StatusOpen {
		panic("bountyboard: can only cancel an open bounty")
	}
	if caller != b.Creator {
		panic("bountyboard: only the creator can cancel")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(realmAddr, b.Creator, chain.Coins{chain.NewCoin("ugnot", b.Reward)})

	b.Status = StatusCancelled
}

func Render(path string) string {
	out := "# Bounty Board\n\n"
	out += ufmt.Sprintf("Total bounties: %d\n\n", bounties.Size())
	bounties.Iterate("", "", func(key string, value interface{}) bool {
		b := value.(*Bounty)
		out += ufmt.Sprintf("## #%d: %s\n", b.ID, b.Title)
		out += ufmt.Sprintf("Status: %s | Reward: %d ugnot | Creator: %s\n\n",
			b.Status.String(), b.Reward, b.Creator)
		return false
	})
	return out
}
