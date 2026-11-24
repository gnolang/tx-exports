// Package bountyboard is an on-chain bounty board with GNOT escrow.
//
// Anyone can post a bounty with a GNOT reward locked in the realm,
// anyone can submit work, and the poster releases the escrow to the
// winner. Open, permissionless, and rendered natively in gnoweb.
package bountyboard

import (
	"std"
	"strconv"

	"gno.land/p/nt/avl"
)

type Bounty struct {
	ID        uint64
	Poster    std.Address
	Title     string
	Desc      string
	Reward    std.Coin
	Open      bool
}

type Submission struct {
	BountyID  uint64
	Submitter std.Address
	URL       string
	Note      string
}

var (
	bounties    avl.Tree // id -> Bounty
	submissions avl.Tree // "bountyID:index" -> Submission
	subCount    avl.Tree // bountyID -> int
	nextID      uint64
)

// PostBounty creates a bounty. Attach the reward as GNOT with the call;
// it stays escrowed in the realm until released or cancelled.
func PostBounty(title, desc string) uint64 {
	reward := std.GetOrigSend()
	if reward.Denom != "ugnot" || reward.Amount <= 0 {
		panic("bounty requires a ugnot payment attached to the call")
	}
	if title == "" {
		panic("title required")
	}
	nextID++
	b := Bounty{
		ID:        nextID,
		Poster:    std.GetOrigCaller(),
		Title:     title,
		Desc:      desc,
		Reward:    reward,
		Open:      true,
	}
	bounties.Set(strconv.FormatUint(b.ID, 10), b)
	return b.ID
}

// SubmitWork enters work for an open bounty.
func SubmitWork(bountyID uint64, url, note string) {
	b := mustBounty(bountyID)
	if !b.Open {
		panic("bounty is closed")
	}
	if url == "" {
		panic("work url required")
	}
	key := strconv.FormatUint(bountyID, 10)
	n := 0
	if v, ok := subCount.Get(key); ok {
		n = v.(int)
	}
	s := Submission{
		BountyID:  bountyID,
		Submitter: std.GetOrigCaller(),
		URL:       url,
		Note:      note,
	}
	submissions.Set(key+":"+strconv.Itoa(n), s)
	subCount.Set(key, n+1)
}

// Release pays the escrowed reward to the chosen submission. Poster only.
func Release(bountyID uint64, submissionIndex int) {
	caller := std.GetOrigCaller()
	b := mustBounty(bountyID)
	if caller != b.Poster {
		panic("only the poster can release the bounty")
	}
	if !b.Open {
		panic("bounty is closed")
	}
	key := strconv.FormatUint(bountyID, 10)
	v, ok := submissions.Get(key + ":" + strconv.Itoa(submissionIndex))
	if !ok {
		panic("no such submission")
	}
	s := v.(Submission)

	banker := std.GetBanker(std.BankerTypeRealmSend)
	if err := banker.SendCoins(std.GetRealmAddress(), s.Submitter, std.Coins{b.Reward}); err != nil {
		panic(err)
	}
	b.Open = false
	bounties.Set(key, b)
}

// Cancel returns the escrow to the poster if there are no submissions yet.
func Cancel(bountyID uint64) {
	caller := std.GetOrigCaller()
	b := mustBounty(bountyID)
	if caller != b.Poster {
		panic("only the poster can cancel")
	}
	if !b.Open {
		panic("bounty is closed")
	}
	key := strconv.FormatUint(bountyID, 10)
	if v, ok := subCount.Get(key); ok && v.(int) > 0 {
		panic("cannot cancel with submissions; release instead")
	}
	banker := std.GetBanker(std.BankerTypeRealmSend)
	if err := banker.SendCoins(std.GetRealmAddress(), b.Poster, std.Coins{b.Reward}); err != nil {
		panic(err)
	}
	b.Open = false
	bounties.Set(key, b)
}

func mustBounty(id uint64) Bounty {
	v, ok := bounties.Get(strconv.FormatUint(id, 10))
	if !ok {
		panic("no such bounty")
	}
	return v.(Bounty)
}

// GetBounty returns a bounty by id (for off-chain reads via vm/qeval).
func GetBounty(id uint64) Bounty { return mustBounty(id) }

// GetSubmission returns submission i of bounty id (for vm/qeval).
func GetSubmission(id uint64, i int) Submission {
	v, ok := submissions.Get(strconv.FormatUint(id, 10)+":"+strconv.Itoa(i))
	if !ok {
		panic("no such submission")
	}
	return v.(Submission)
}

// Render shows the board in gnoweb.
func Render(path string) string {
	out := "# Gno Bounty Board\n\n"
	out += "Post a bounty with GNOT escrow. Submit work. Poster releases the reward on-chain.\n\n"
	out += "---\n\n"
	for i := nextID; i >= 1; i-- {
		v, ok := bounties.Get(strconv.FormatUint(i, 10))
		if !ok {
			continue
		}
		b := v.(Bounty)
		status := "OPEN"
		if !b.Open {
			status = "CLOSED"
		}
		out += "## #" + strconv.FormatUint(i, 10) + " " + b.Title + " [" + status + "]\n\n"
		out += b.Desc + "\n\n"
		out += "- Reward: `" + b.Reward.String() + "`\n"
		out += "- Poster: `" + string(b.Poster) + "`\n"
		if n, ok := subCount.Get(strconv.FormatUint(i, 10)); ok {
			out += "- Submissions: " + strconv.Itoa(n.(int)) + "\n"
		}
		out += "\n"
	}
	if nextID == 0 {
		out += "_No bounties yet. Be the first to post one._\n"
	}
	return out
}
