// Package tavernescrow implements an on-chain milestone bounty escrow & reputation board
// for the Gno.land ecosystem (Gnome Tavern Hackathon - $20,000 GNOT).
// Note: Package name intentionally does NOT start with "Gno" per hackathon naming rules.
package tavernescrow

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type Status string

const (
	StatusOpen      Status = "OPEN"
	StatusSubmitted Status = "SUBMITTED"
	StatusApproved  Status = "APPROVED"
	StatusCancelled Status = "CANCELLED"
)

type Bounty struct {
	ID            uint64
	Title         string
	Description   string
	Sponsor       address
	Hunter        address
	ProofURL      string
	RewardAmount  int64
	RewardDenom   string
	Status        Status
	CreatedHeight int64
}

type HunterStats struct {
	Completed uint64
	Earned    int64
}

var (
	bounties  *avl.Tree // key: zero-padded ID -> *Bounty
	hunters   *avl.Tree // key: hunter address string -> *HunterStats
	nextID    uint64
	totalPaid int64
	paidCount uint64
)

func init() {
	bounties = avl.NewTree()
	hunters = avl.NewTree()
	nextID = 1
}

func padID(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

// CreateBounty locks ugnot sent via direct user-call (maketx call) into realm escrow.
// Requiring IsUserCall() guards against phantom OriginSend() draining attacks from intermediate realms.
func CreateBounty(cur realm, title, description string) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("only direct user-call (maketx call) accepted")
	}
	title = strings.TrimSpace(title)
	description = strings.TrimSpace(description)
	if title == "" {
		panic("title cannot be empty")
	}
	if len(title) > 120 {
		panic("title exceeds 120 chars")
	}
	sent := unsafe.OriginSend()
	ugnot := sent.AmountOf("ugnot")
	if ugnot <= 0 {
		panic("must attach positive ugnot reward to lock in escrow")
	}

	caller := cur.Previous().Address()
	id := nextID
	nextID++

	b := &Bounty{
		ID:            id,
		Title:         title,
		Description:   description,
		Sponsor:       caller,
		RewardAmount:  ugnot,
		RewardDenom:   "ugnot",
		Status:        StatusOpen,
		CreatedHeight: runtime.ChainHeight(),
	}
	bounties.Set(padID(id), b)
	return id
}

// SubmitWork lets any contributor attach a verifiable https:// proof URL to an OPEN bounty.
func SubmitWork(cur realm, id uint64, proofURL string) {
	proofURL = strings.TrimSpace(proofURL)
	if !strings.HasPrefix(proofURL, "https://") {
		panic("proofURL must start with https://")
	}
	raw := bounties.Get(padID(id))
	if raw == nil {
		panic("bounty not found")
	}
	b := raw.(*Bounty)
	if b.Status != StatusOpen {
		panic("bounty is not OPEN")
	}
	caller := cur.Previous().Address()
	if caller == b.Sponsor {
		panic("sponsor cannot claim own bounty")
	}
	b.Hunter = caller
	b.ProofURL = proofURL
	b.Status = StatusSubmitted
}

// ApproveAndPay releases locked ugnot escrow directly to the hunter and records on-chain reputation.
func ApproveAndPay(cur realm, id uint64) {
	raw := bounties.Get(padID(id))
	if raw == nil {
		panic("bounty not found")
	}
	b := raw.(*Bounty)
	if b.Status != StatusSubmitted {
		panic("bounty must be SUBMITTED before approval")
	}
	caller := cur.Previous().Address()
	if caller != b.Sponsor {
		panic("only sponsor can approve payout")
	}

	// Update state before external bank transfer (checks-effects-interactions)
	b.Status = StatusApproved
	totalPaid += b.RewardAmount
	paidCount++

	hKey := b.Hunter.String()
	var stats *HunterStats
	if existing := hunters.Get(hKey); existing != nil {
		stats = existing.(*HunterStats)
	} else {
		stats = &HunterStats{}
		hunters.Set(hKey, stats)
	}
	stats.Completed++
	stats.Earned += b.RewardAmount

	pkgAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(pkgAddr, b.Hunter, chain.Coins{chain.NewCoin(b.RewardDenom, b.RewardAmount)})
}

// RejectSubmission returns a SUBMITTED bounty back to OPEN so another hunter can complete it.
func RejectSubmission(cur realm, id uint64) {
	raw := bounties.Get(padID(id))
	if raw == nil {
		panic("bounty not found")
	}
	b := raw.(*Bounty)
	if b.Status != StatusSubmitted {
		panic("bounty must be SUBMITTED to reject")
	}
	if cur.Previous().Address() != b.Sponsor {
		panic("only sponsor can reject submission")
	}
	b.Hunter = ""
	b.ProofURL = ""
	b.Status = StatusOpen
}

// CancelBounty refunds locked ugnot to the sponsor if no submission has been approved yet.
func CancelBounty(cur realm, id uint64) {
	raw := bounties.Get(padID(id))
	if raw == nil {
		panic("bounty not found")
	}
	b := raw.(*Bounty)
	if b.Status != StatusOpen && b.Status != StatusSubmitted {
		panic("bounty cannot be cancelled in current state")
	}
	caller := cur.Previous().Address()
	if caller != b.Sponsor {
		panic("only sponsor can cancel")
	}

	b.Status = StatusCancelled
	pkgAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(pkgAddr, b.Sponsor, chain.Coins{chain.NewCoin(b.RewardDenom, b.RewardAmount)})
}

// GetStats returns aggregate escrow counters for programmatic consumers.
func GetStats() (totalBounties int, settled uint64, paidUgnot int64) {
	return bounties.Size(), paidCount, totalPaid
}

// Render provides a live gnoweb Markdown dashboard for browsing bounties, proofs, and hunter reputation.
func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("# TavernEscrow - On-Chain Bounty & Milestone Escrow\n\n")
	sb.WriteString(ufmt.Sprintf("**Total Bounties:** %d | **Settled Payouts:** %d | **Total Paid:** %d ugnot\n\n",
		bounties.Size(), paidCount, totalPaid))

	if strings.HasPrefix(path, "bounty/") {
		idStr := strings.TrimPrefix(path, "bounty/")
		id, err := strconv.ParseUint(idStr, 10, 64)
		if err != nil {
			return "Invalid bounty ID."
		}
		raw := bounties.Get(padID(id))
		if raw == nil {
			return "Bounty not found."
		}
		b := raw.(*Bounty)
		sb.WriteString(ufmt.Sprintf("## Bounty #%d - %s\n\n", b.ID, b.Title))
		sb.WriteString(ufmt.Sprintf("- **Status:** `%s`\n", string(b.Status)))
		sb.WriteString(ufmt.Sprintf("- **Reward Locked:** `%d %s`\n", b.RewardAmount, b.RewardDenom))
		sb.WriteString(ufmt.Sprintf("- **Sponsor:** `%s`\n", b.Sponsor.String()))
		if b.Hunter != "" {
			sb.WriteString(ufmt.Sprintf("- **Hunter:** `%s`\n", b.Hunter.String()))
			sb.WriteString(ufmt.Sprintf("- **Proof:** %s\n", b.ProofURL))
		}
		sb.WriteString(ufmt.Sprintf("\n### Specification\n%s\n\n[<- Back to Board](.)\n", b.Description))
		return sb.String()
	}

	sb.WriteString("## Active & Settled Bounties\n\n")
	sb.WriteString("| # | Title | Reward | Status | Sponsor |\n")
	sb.WriteString("|---|---|---|---|---|\n")
	bounties.ReverseIterate("", "", func(key string, value any) bool {
		b := value.(*Bounty)
		sb.WriteString(ufmt.Sprintf("| [#%d](:bounty/%d) | %s | %d %s | `%s` | `%s` |\n",
			b.ID, b.ID, b.Title, b.RewardAmount, b.RewardDenom, string(b.Status), b.Sponsor.String()))
		return false
	})
	if bounties.Size() == 0 {
		sb.WriteString("| - | No bounties posted yet - call `CreateBounty` with ugnot! | - | - | - |\n")
	}

	if hunters.Size() > 0 {
		sb.WriteString("\n## Verified Hunter Reputation\n\n")
		sb.WriteString("| Hunter | Completed | Total Earned |\n")
		sb.WriteString("|---|---|---|\n")
		hunters.Iterate("", "", func(key string, value any) bool {
			st := value.(*HunterStats)
			sb.WriteString(ufmt.Sprintf("| `%s` | %d | %d ugnot |\n", key, st.Completed, st.Earned))
			return false
		})
	}
	return sb.String()
}
