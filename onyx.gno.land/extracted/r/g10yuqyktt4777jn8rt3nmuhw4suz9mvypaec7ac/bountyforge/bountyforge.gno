// Package bountyforge implements a trustless on-chain micro-bounty escrow,
// multi-contributor basis-point payout splitter, optional arbiter dispute
// resolution, and verifiable builder reputation board on Gno.land.
package bountyforge

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/escrowmath"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	StatusOpen      = "OPEN"
	StatusPaid      = "PAID"
	StatusCancelled = "CANCELLED"
	StatusDisputed  = "DISPUTED"

	MinRewardUgnot int64 = 1000 // 0.001 GNOT minimum to prevent dust spam
	MaxTitleLen          = 120
	MaxSummaryLen        = 600
	MaxTagsLen           = 120
	MaxProofURLLen       = 300
	MaxNotesLen          = 400
	MaxSubmissions       = 50
)

// Submission represents a contributor's proof-of-work entry for a bounty.
type Submission struct {
	Index      int
	Builder    address
	ProofURL   string
	Notes      string
	SubmittedH int64
}

// PayoutRecord tracks a single on-chain disbursement made from a bounty.
type PayoutRecord struct {
	Recipient address
	Amount    int64
	Bps       int64
}

// Bounty holds all escrow, submission, dispute, and settlement state.
type Bounty struct {
	ID            uint64
	Title         string
	Summary       string
	Tags          string
	Creator       address
	Arbiter       address // optional; empty string if no arbiter configured
	RewardUgnot   int64
	Status        string
	CreatedHeight int64
	DeadlineH     int64 // 0 means no deadline expiry
	DisputeReason string
	Submissions   []*Submission
	Payouts       []*PayoutRecord
}

// BuilderProfile stores cumulative on-chain reputation and earnings.
type BuilderProfile struct {
	Address     address
	Completed   int
	TotalEarned int64
	XP          int64
	LastHeight  int64
}

var (
	nextID        seqid.ID
	bounties      *avl.Tree // key: seqid.ID.String() -> *Bounty
	builders      *avl.Tree // key: address.String() -> *BuilderProfile
	totalEscrowed int64
	totalPaidOut  int64
	openCount     int
	paidCount     int
	disputedCount int
	cancelledCnt  int
	router        *mux.Router
)

func init() {
	resetState()
}

func resetState() {
	nextID = 0
	bounties = avl.NewTree()
	builders = avl.NewTree()
	totalEscrowed = 0
	totalPaidOut = 0
	openCount = 0
	paidCount = 0
	disputedCount = 0
	cancelledCnt = 0
	initRouter()
}

func initRouter() {
	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("bounty/{id}", renderBountyDetail)
	router.HandleFunc("builder/{addr}", renderBuilderProfile)
	router.HandleFunc("leaderboard", renderLeaderboard)
	router.HandleFunc("stats", renderStats)
	router.SetNotFoundHandler(func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write("# BountyForge — 404 Not Found\n\n")
		res.Write("Unknown route `" + escrowmath.SanitizeInline(req.Path, 80) + "`.\n\n")
		res.Write("[Back to Board](:)\n")
	})
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

func requireUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("bountyforge: only direct user calls (maketx call) are accepted")
	}
	return cur.Previous().Address()
}

func ugnotFromCoins(coins chain.Coins) int64 {
	var total int64
	for _, c := range coins {
		if c.Denom == "ugnot" {
			total += c.Amount
		}
	}
	return total
}

func getBountyByUint64(id uint64) (*Bounty, string) {
	if id == 0 {
		panic("bountyforge: invalid bounty id 0")
	}
	key := seqid.ID(id).String()
	raw := bounties.Get(key)
	if raw == nil {
		panic(ufmt.Sprintf("bountyforge: bounty #%d not found", id))
	}
	return raw.(*Bounty), key
}

func creditBuilder(addr address, ugnot int64, height int64) {
	key := addr.String()
	var prof *BuilderProfile
	if raw := builders.Get(key); raw != nil {
		prof = raw.(*BuilderProfile)
	} else {
		prof = &BuilderProfile{Address: addr}
	}
	prof.Completed++
	prof.TotalEarned += ugnot
	prof.XP += escrowmath.ComputeXP(ugnot)
	prof.LastHeight = height
	builders.Set(key, prof)
}

func releaseFunds(cur realm, recipient address, ugnot int64) {
	if ugnot <= 0 {
		return
	}
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if b.GetCoin(realmAddr, "ugnot") < ugnot {
		panic("bountyforge: insufficient realm balance for payout")
	}
	b.SendCoins(realmAddr, recipient, chain.Coins{chain.NewCoin("ugnot", ugnot)})
}

func parseIntList(csv string) []int {
	parts := strings.Split(strings.TrimSpace(csv), ",")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			panic("bountyforge: empty integer entry in CSV")
		}
		v, err := strconv.Atoi(p)
		if err != nil {
			panic("bountyforge: invalid integer in CSV: " + p)
		}
		out = append(out, v)
	}
	return out
}

func parseInt64List(csv string) []int64 {
	parts := strings.Split(strings.TrimSpace(csv), ",")
	out := make([]int64, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			panic("bountyforge: empty int64 entry in CSV")
		}
		v, err := strconv.ParseInt(p, 10, 64)
		if err != nil {
			panic("bountyforge: invalid int64 in CSV: " + p)
		}
		out = append(out, v)
	}
	return out
}

// ---------------------------------------------------------------------------
// Public Realm Transactions
// ---------------------------------------------------------------------------

// CreateBounty locks attached ugnot into on-chain escrow and opens a new bounty.
// arbiterStr may be empty if no third-party dispute arbiter is needed.
// deadlineBlocks sets expiry relative to current block height (0 = no expiry).
func CreateBounty(cur realm, title, summary, tags, arbiterStr string, deadlineBlocks int64) uint64 {
	caller := requireUserCall(cur)

	cleanTitle := escrowmath.SanitizeInline(title, MaxTitleLen)
	if cleanTitle == "" {
		panic("bountyforge: title cannot be empty")
	}
	cleanSummary := escrowmath.SanitizeInline(summary, MaxSummaryLen)
	if cleanSummary == "" {
		panic("bountyforge: summary cannot be empty")
	}
	cleanTags := escrowmath.SanitizeInline(tags, MaxTagsLen)
	if deadlineBlocks < 0 {
		panic("bountyforge: deadlineBlocks cannot be negative")
	}

	var arbiter address
	arbiterStr = strings.TrimSpace(arbiterStr)
	if arbiterStr != "" {
		arbiter = address(arbiterStr)
		if !arbiter.IsValid() {
			panic("bountyforge: invalid arbiter address")
		}
		if arbiter == caller {
			panic("bountyforge: creator cannot be their own arbiter")
		}
	}

	amt := ugnotFromCoins(unsafe.OriginSend())
	if amt < MinRewardUgnot {
		panic(ufmt.Sprintf("bountyforge: reward must be at least %d ugnot", MinRewardUgnot))
	}

	// Enforce solvency invariant: realm balance must cover all existing escrow + new deposit.
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if b.GetCoin(realmAddr, "ugnot") < totalEscrowed+amt {
		panic("bountyforge: realm balance did not receive declared ugnot deposit")
	}

	height := runtime.ChainHeight()
	var deadlineH int64
	if deadlineBlocks > 0 {
		deadlineH = height + deadlineBlocks
	}

	id := nextID.Next()
	bounty := &Bounty{
		ID:            uint64(id),
		Title:         cleanTitle,
		Summary:       cleanSummary,
		Tags:          cleanTags,
		Creator:       caller,
		Arbiter:       arbiter,
		RewardUgnot:   amt,
		Status:        StatusOpen,
		CreatedHeight: height,
		DeadlineH:     deadlineH,
	}

	bounties.Set(id.String(), bounty)
	totalEscrowed += amt
	openCount++

	chain.Emit(
		"BountyCreated",
		"id", strconv.FormatUint(bounty.ID, 10),
		"creator", caller.String(),
		"reward_ugnot", strconv.FormatInt(amt, 10),
		"arbiter", arbiter.String(),
	)
	return bounty.ID
}

// TopUpBounty allows any sponsor to add extra ugnot to an existing OPEN bounty.
func TopUpBounty(cur realm, bountyID uint64) int64 {
	caller := requireUserCall(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusOpen {
		panic("bountyforge: can only top up an OPEN bounty")
	}

	amt := ugnotFromCoins(unsafe.OriginSend())
	if amt <= 0 {
		panic("bountyforge: top-up amount must be positive")
	}

	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if b.GetCoin(realmAddr, "ugnot") < totalEscrowed+amt {
		panic("bountyforge: realm balance did not receive top-up ugnot")
	}

	bounty.RewardUgnot += amt
	totalEscrowed += amt

	chain.Emit(
		"BountyToppedUp",
		"id", strconv.FormatUint(bounty.ID, 10),
		"sponsor", caller.String(),
		"added_ugnot", strconv.FormatInt(amt, 10),
		"new_reward_ugnot", strconv.FormatInt(bounty.RewardUgnot, 10),
	)
	return bounty.RewardUgnot
}

// SubmitWork registers a builder's deliverable proof URL and notes on an OPEN bounty.
func SubmitWork(cur realm, bountyID uint64, proofURL, notes string) int {
	caller := requireUserCall(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusOpen {
		panic("bountyforge: submissions are only accepted on OPEN bounties")
	}
	if caller == bounty.Creator {
		panic("bountyforge: bounty creator cannot submit work to their own bounty")
	}
	if bounty.Arbiter != "" && caller == bounty.Arbiter {
		panic("bountyforge: bounty arbiter cannot submit work")
	}
	if len(bounty.Submissions) >= MaxSubmissions {
		panic("bountyforge: maximum submissions reached for this bounty")
	}

	cleanProof := escrowmath.SanitizeInline(proofURL, MaxProofURLLen)
	if cleanProof == "" {
		panic("bountyforge: proofURL cannot be empty")
	}
	cleanNotes := escrowmath.SanitizeInline(notes, MaxNotesLen)

	// Allow updating an existing submission from the same builder instead of spamming duplicates.
	for _, sub := range bounty.Submissions {
		if sub.Builder == caller {
			sub.ProofURL = cleanProof
			sub.Notes = cleanNotes
			sub.SubmittedH = runtime.ChainHeight()
			chain.Emit(
				"WorkUpdated",
				"id", strconv.FormatUint(bounty.ID, 10),
				"builder", caller.String(),
				"index", strconv.Itoa(sub.Index),
			)
			return sub.Index
		}
	}

	idx := len(bounty.Submissions)
	bounty.Submissions = append(bounty.Submissions, &Submission{
		Index:      idx,
		Builder:    caller,
		ProofURL:   cleanProof,
		Notes:      cleanNotes,
		SubmittedH: runtime.ChainHeight(),
	})

	chain.Emit(
		"WorkSubmitted",
		"id", strconv.FormatUint(bounty.ID, 10),
		"builder", caller.String(),
		"index", strconv.Itoa(idx),
	)
	return idx
}

// ApproveAndPay releases 100% of a bounty's escrowed ugnot to the winning builder.
func ApproveAndPay(cur realm, bountyID uint64, submissionIdx int) {
	caller := requireUserCall(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if caller != bounty.Creator {
		panic("bountyforge: only the bounty creator can approve payout")
	}
	if bounty.Status != StatusOpen {
		panic("bountyforge: bounty is not OPEN")
	}
	if submissionIdx < 0 || submissionIdx >= len(bounty.Submissions) {
		panic("bountyforge: submission index out of range")
	}

	winner := bounty.Submissions[submissionIdx].Builder
	amount := bounty.RewardUgnot

	// Effects before interactions (CEI pattern).
	bounty.Status = StatusPaid
	bounty.Payouts = []*PayoutRecord{
		{Recipient: winner, Amount: amount, Bps: escrowmath.TotalBPS},
	}
	totalEscrowed -= amount
	totalPaidOut += amount
	openCount--
	paidCount++
	creditBuilder(winner, amount, runtime.ChainHeight())

	releaseFunds(cur, winner, amount)

	chain.Emit(
		"BountyPaid",
		"id", strconv.FormatUint(bounty.ID, 10),
		"winner", winner.String(),
		"amount_ugnot", strconv.FormatInt(amount, 10),
	)
}

// SplitAndPay splits a bounty's escrow across multiple contributors using exact
// dust-conserving basis points (must sum to 10000).
func SplitAndPay(cur realm, bountyID uint64, indicesCSV, bpsCSV string) {
	caller := requireUserCall(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if caller != bounty.Creator {
		panic("bountyforge: only the bounty creator can split payout")
	}
	if bounty.Status != StatusOpen {
		panic("bountyforge: bounty is not OPEN")
	}

	indices := parseIntList(indicesCSV)
	bps := parseInt64List(bpsCSV)
	if len(indices) != len(bps) {
		panic("bountyforge: submission indices and basis-point weights must have equal length")
	}

	seen := make(map[int]bool, len(indices))
	recipients := make([]address, len(indices))
	for i, idx := range indices {
		if idx < 0 || idx >= len(bounty.Submissions) {
			panic("bountyforge: submission index out of range")
		}
		if seen[idx] {
			panic("bountyforge: duplicate submission index in split")
		}
		seen[idx] = true
		recipients[i] = bounty.Submissions[idx].Builder
	}

	shares, err := escrowmath.SplitBasisPoints(bounty.RewardUgnot, bps)
	if err != nil {
		panic(err.Error())
	}

	amount := bounty.RewardUgnot
	height := runtime.ChainHeight()

	// Effects before interactions.
	bounty.Status = StatusPaid
	bounty.Payouts = make([]*PayoutRecord, len(recipients))
	for i, rec := range recipients {
		bounty.Payouts[i] = &PayoutRecord{
			Recipient: rec,
			Amount:    shares[i],
			Bps:       bps[i],
		}
		creditBuilder(rec, shares[i], height)
	}
	totalEscrowed -= amount
	totalPaidOut += amount
	openCount--
	paidCount++

	for i, rec := range recipients {
		releaseFunds(cur, rec, shares[i])
	}

	chain.Emit(
		"BountySplitPaid",
		"id", strconv.FormatUint(bounty.ID, 10),
		"recipients", strconv.Itoa(len(recipients)),
		"amount_ugnot", strconv.FormatInt(amount, 10),
	)
}

// CancelAndRefund lets the creator reclaim escrowed ugnot if there are zero
// submissions OR if the bounty's block deadline has passed without dispute.
func CancelAndRefund(cur realm, bountyID uint64) {
	caller := requireUserCall(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if caller != bounty.Creator {
		panic("bountyforge: only the bounty creator can cancel")
	}
	if bounty.Status != StatusOpen {
		panic("bountyforge: only OPEN bounties can be cancelled")
	}
	if len(bounty.Submissions) > 0 {
		if bounty.DeadlineH == 0 || runtime.ChainHeight() <= bounty.DeadlineH {
			panic("bountyforge: cannot cancel while submissions exist before deadline")
		}
	}

	refund := bounty.RewardUgnot
	bounty.Status = StatusCancelled
	totalEscrowed -= refund
	openCount--
	cancelledCnt++

	releaseFunds(cur, bounty.Creator, refund)

	chain.Emit(
		"BountyCancelled",
		"id", strconv.FormatUint(bounty.ID, 10),
		"creator", bounty.Creator.String(),
		"refund_ugnot", strconv.FormatInt(refund, 10),
	)
}

// OpenDispute freezes an OPEN bounty with a configured arbiter for resolution.
// Either the creator or any builder who submitted work may open a dispute.
func OpenDispute(cur realm, bountyID uint64, reason string) {
	caller := requireUserCall(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusOpen {
		panic("bountyforge: only OPEN bounties can enter dispute")
	}
	if bounty.Arbiter == "" {
		panic("bountyforge: bounty has no arbiter configured")
	}
	if len(bounty.Submissions) == 0 {
		panic("bountyforge: cannot dispute a bounty with zero submissions")
	}

	authorized := caller == bounty.Creator
	if !authorized {
		for _, sub := range bounty.Submissions {
			if sub.Builder == caller {
				authorized = true
				break
			}
		}
	}
	if !authorized {
		panic("bountyforge: only creator or a submitter can open a dispute")
	}

	cleanReason := escrowmath.SanitizeInline(reason, MaxNotesLen)
	if cleanReason == "" {
		panic("bountyforge: dispute reason cannot be empty")
	}

	bounty.Status = StatusDisputed
	bounty.DisputeReason = cleanReason
	openCount--
	disputedCount++

	chain.Emit(
		"DisputeOpened",
		"id", strconv.FormatUint(bounty.ID, 10),
		"opened_by", caller.String(),
		"arbiter", bounty.Arbiter.String(),
	)
}

// ResolveDispute allows the designated arbiter to settle a DISPUTED bounty by
// awarding builderBps (0..10000) to the selected submitter and refunding the
// remaining basis points to the creator.
func ResolveDispute(cur realm, bountyID uint64, submissionIdx int, builderBps int64) {
	caller := requireUserCall(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusDisputed {
		panic("bountyforge: bounty is not DISPUTED")
	}
	if caller != bounty.Arbiter {
		panic("bountyforge: only the designated arbiter can resolve disputes")
	}
	if builderBps < 0 || builderBps > escrowmath.TotalBPS {
		panic("bountyforge: builderBps must be between 0 and 10000")
	}
	if submissionIdx < 0 || submissionIdx >= len(bounty.Submissions) {
		panic("bountyforge: submission index out of range")
	}

	builder := bounty.Submissions[submissionIdx].Builder
	total := bounty.RewardUgnot
	var builderShare, creatorRefund int64

	switch builderBps {
	case 0:
		creatorRefund = total
	case escrowmath.TotalBPS:
		builderShare = total
	default:
		shares, err := escrowmath.SplitBasisPoints(total, []int64{builderBps, escrowmath.TotalBPS - builderBps})
		if err != nil {
			panic(err.Error())
		}
		builderShare = shares[0]
		creatorRefund = shares[1]
	}

	// Effects before interactions.
	totalEscrowed -= total
	disputedCount--
	if builderShare > 0 {
		bounty.Status = StatusPaid
		paidCount++
		totalPaidOut += builderShare
		bounty.Payouts = []*PayoutRecord{
			{Recipient: builder, Amount: builderShare, Bps: builderBps},
		}
		if creatorRefund > 0 {
			bounty.Payouts = append(bounty.Payouts, &PayoutRecord{
				Recipient: bounty.Creator,
				Amount:    creatorRefund,
				Bps:       escrowmath.TotalBPS - builderBps,
			})
		}
		creditBuilder(builder, builderShare, runtime.ChainHeight())
	} else {
		bounty.Status = StatusCancelled
		cancelledCnt++
	}

	if builderShare > 0 {
		releaseFunds(cur, builder, builderShare)
	}
	if creatorRefund > 0 {
		releaseFunds(cur, bounty.Creator, creatorRefund)
	}

	chain.Emit(
		"DisputeResolved",
		"id", strconv.FormatUint(bounty.ID, 10),
		"arbiter", caller.String(),
		"builder_ugnot", strconv.FormatInt(builderShare, 10),
		"creator_refund_ugnot", strconv.FormatInt(creatorRefund, 10),
	)
}

// ---------------------------------------------------------------------------
// Read-Only View Functions (ABCI vm/qeval friendly)
// ---------------------------------------------------------------------------

// TotalEscrowed returns the total ugnot currently locked across active bounties.
func TotalEscrowed() int64 {
	return totalEscrowed
}

// TotalPaidOut returns cumulative ugnot paid to builders across all settled bounties.
func TotalPaidOut() int64 {
	return totalPaidOut
}

// BountyCount returns total number of bounties created.
func BountyCount() int {
	return bounties.Size()
}

// BuilderXP returns the accumulated reputation XP for a builder address.
func BuilderXP(addr address) int64 {
	raw := builders.Get(addr.String())
	if raw == nil {
		return 0
	}
	return raw.(*BuilderProfile).XP
}

// ---------------------------------------------------------------------------
// gnoweb Markdown Render Entrypoint
// ---------------------------------------------------------------------------

// Render serves human- and AI-readable Markdown pages over gnoweb.
func Render(path string) string {
	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	filter := strings.ToUpper(strings.TrimSpace(req.Query.Get("status")))

	res.Write("# BountyForge — On-Chain Micro-Bounty Escrow & Builder Reputation\n\n")
	res.Write("Trustless GNOT escrow, dust-free basis-point split payouts, optional arbiter dispute resolution, and verifiable builder XP on Gno.land.\n\n")
	res.Write(ufmt.Sprintf(
		"**Locked Escrow:** %s | **Total Paid:** %s | **Open:** %d | **Paid:** %d | **Disputed:** %d | **Builders:** %d\n\n",
		escrowmath.FormatGNOT(totalEscrowed),
		escrowmath.FormatGNOT(totalPaidOut),
		openCount,
		paidCount,
		disputedCount,
		builders.Size(),
	))
	res.Write("[All](:) · [Open](:?status=OPEN) · [Paid](:?status=PAID) · [Disputed](:?status=DISPUTED) · [Leaderboard](:leaderboard) · [Protocol Stats](:stats)\n\n")

	if bounties.Size() == 0 {
		res.Write("_No bounties posted yet. Call `CreateBounty` with `-send` GNOT to fund the first quest!_\n")
		return
	}

	res.Write("| ID | Title | Reward | Status | Submissions | Tags |\n")
	res.Write("|---|---|---|---|---|---|\n")

	shown := 0
	bounties.ReverseIterate("", "", func(_ string, val any) bool {
		b := val.(*Bounty)
		if filter != "" && b.Status != filter {
			return false
		}
		res.Write(ufmt.Sprintf(
			"| [#%d](:bounty/%d) | %s | %s | `%s` | %d | %s |\n",
			b.ID,
			b.ID,
			b.Title,
			escrowmath.FormatGNOT(b.RewardUgnot),
			b.Status,
			len(b.Submissions),
			b.Tags,
		))
		shown++
		return shown >= 50
	})

	if shown == 0 {
		res.Write(ufmt.Sprintf("\n_No bounties match status `%s`._\n", escrowmath.SanitizeInline(filter, 20)))
	}
}

func renderBountyDetail(res *mux.ResponseWriter, req *mux.Request) {
	rawID := req.GetVar("id")
	idNum, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil || idNum == 0 {
		res.Write("# Invalid Bounty ID\n\n[Back to Board](:)\n")
		return
	}
	raw := bounties.Get(seqid.ID(idNum).String())
	if raw == nil {
		res.Write(ufmt.Sprintf("# Bounty #%d Not Found\n\n[Back to Board](:)\n", idNum))
		return
	}
	b := raw.(*Bounty)

	res.Write(ufmt.Sprintf("# Bounty #%d: %s\n\n", b.ID, b.Title))
	res.Write(ufmt.Sprintf("- **Status:** `%s`\n", b.Status))
	res.Write(ufmt.Sprintf("- **Reward Pool:** %s (`%d ugnot`)\n", escrowmath.FormatGNOT(b.RewardUgnot), b.RewardUgnot))
	res.Write(ufmt.Sprintf("- **Creator:** `%s`\n", b.Creator.String()))
	if b.Arbiter != "" {
		res.Write(ufmt.Sprintf("- **Dispute Arbiter:** `%s`\n", b.Arbiter.String()))
	} else {
		res.Write("- **Dispute Arbiter:** _None (creator-managed)_\n")
	}
	if b.DeadlineH > 0 {
		res.Write(ufmt.Sprintf("- **Deadline Height:** #%d (current: #%d)\n", b.DeadlineH, runtime.ChainHeight()))
	} else {
		res.Write("- **Deadline Height:** _No expiry_\n")
	}
	if b.Tags != "" {
		res.Write(ufmt.Sprintf("- **Tags:** `%s`\n", b.Tags))
	}
	res.Write("\n## Specification\n\n" + b.Summary + "\n\n")

	if b.DisputeReason != "" {
		res.Write("## Dispute Notice\n\n> " + b.DisputeReason + "\n\n")
	}

	res.Write(ufmt.Sprintf("## Submissions (%d)\n\n", len(b.Submissions)))
	if len(b.Submissions) == 0 {
		res.Write("_No submissions yet._\n\n")
	} else {
		res.Write("| # | Builder | Proof | Notes | Block |\n")
		res.Write("|---|---|---|---|---|\n")
		for _, sub := range b.Submissions {
			res.Write(ufmt.Sprintf(
				"| %d | [%s](:builder/%s) | %s | %s | #%d |\n",
				sub.Index,
				shortAddr(sub.Builder),
				sub.Builder.String(),
				sub.ProofURL,
				sub.Notes,
				sub.SubmittedH,
			))
		}
		res.Write("\n")
	}

	if len(b.Payouts) > 0 {
		res.Write("## On-Chain Settlement\n\n")
		res.Write("| Recipient | Share | Amount |\n")
		res.Write("|---|---|---|\n")
		for _, p := range b.Payouts {
			res.Write(ufmt.Sprintf(
				"| [%s](:builder/%s) | %.2f%% | %s |\n",
				shortAddr(p.Recipient),
				p.Recipient.String(),
				float64(p.Bps)/100.0,
				escrowmath.FormatGNOT(p.Amount),
			))
		}
		res.Write("\n")
	}

	res.Write("[Back to Board](:) · [Leaderboard](:leaderboard)\n")
}

func renderBuilderProfile(res *mux.ResponseWriter, req *mux.Request) {
	addrStr := escrowmath.SanitizeInline(req.GetVar("addr"), 64)
	raw := builders.Get(addrStr)
	res.Write("# Builder Profile\n\n")
	res.Write(ufmt.Sprintf("- **Address:** `%s`\n", addrStr))
	if raw == nil {
		res.Write("- **Tier:** `[N]` Novice\n- **XP:** 0\n- **Completed Bounties:** 0\n\n")
		res.Write("[Back to Board](:) · [Leaderboard](:leaderboard)\n")
		return
	}
	prof := raw.(*BuilderProfile)
	tier, badge := escrowmath.TierForXP(prof.XP)
	nextTarget := nextTierTarget(prof.XP)
	res.Write(ufmt.Sprintf("- **Tier:** `%s` %s\n", badge, tier))
	res.Write(ufmt.Sprintf("- **Reputation XP:** %d %s\n", prof.XP, escrowmath.ProgressBar(int(prof.XP), int(nextTarget), 12)))
	res.Write(ufmt.Sprintf("- **Completed Bounties:** %d\n", prof.Completed))
	res.Write(ufmt.Sprintf("- **Total Earned:** %s\n", escrowmath.FormatGNOT(prof.TotalEarned)))
	res.Write(ufmt.Sprintf("- **Last Active Block:** #%d\n\n", prof.LastHeight))
	res.Write("[Back to Board](:) · [Leaderboard](:leaderboard)\n")
}

func renderLeaderboard(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# BountyForge Builder Leaderboard\n\n")
	if builders.Size() == 0 {
		res.Write("_No settled bounties yet._\n\n[Back to Board](:)\n")
		return
	}

	list := make([]*BuilderProfile, 0, builders.Size())
	builders.Iterate("", "", func(_ string, val any) bool {
		list = append(list, val.(*BuilderProfile))
		return false
	})

	// Deterministic insertion sort by XP desc, then TotalEarned desc, then Address asc.
	for i := 1; i < len(list); i++ {
		cur := list[i]
		j := i - 1
		for j >= 0 && betterProfile(cur, list[j]) {
			list[j+1] = list[j]
			j--
		}
		list[j+1] = cur
	}

	res.Write("| Rank | Builder | Tier | XP | Completed | Earned |\n")
	res.Write("|---|---|---|---|---|---|\n")
	for i, prof := range list {
		tier, badge := escrowmath.TierForXP(prof.XP)
		res.Write(ufmt.Sprintf(
			"| %d | [%s](:builder/%s) | `%s` %s | %d | %d | %s |\n",
			i+1,
			shortAddr(prof.Address),
			prof.Address.String(),
			badge,
			tier,
			prof.XP,
			prof.Completed,
			escrowmath.FormatGNOT(prof.TotalEarned),
		))
	}
	res.Write("\n[Back to Board](:) · [Protocol Stats](:stats)\n")
}

func renderStats(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# BountyForge Protocol Stats\n\n")
	res.Write(ufmt.Sprintf("- **Total Bounties:** %d\n", bounties.Size()))
	res.Write(ufmt.Sprintf("- **Open:** %d | **Paid:** %d | **Disputed:** %d | **Cancelled:** %d\n", openCount, paidCount, disputedCount, cancelledCnt))
	res.Write(ufmt.Sprintf("- **Total Locked Escrow:** %s (`%d ugnot`)\n", escrowmath.FormatGNOT(totalEscrowed), totalEscrowed))
	res.Write(ufmt.Sprintf("- **Cumulative Paid Out:** %s (`%d ugnot`)\n", escrowmath.FormatGNOT(totalPaidOut), totalPaidOut))
	res.Write(ufmt.Sprintf("- **Verified Builders:** %d\n", builders.Size()))
	res.Write(ufmt.Sprintf("- **Current Block Height:** #%d\n\n", runtime.ChainHeight()))
	res.Write("[Back to Board](:) · [Leaderboard](:leaderboard)\n")
}

func betterProfile(a, b *BuilderProfile) bool {
	if a.XP != b.XP {
		return a.XP > b.XP
	}
	if a.TotalEarned != b.TotalEarned {
		return a.TotalEarned > b.TotalEarned
	}
	return a.Address.String() < b.Address.String()
}

func nextTierTarget(xp int64) int64 {
	switch {
	case xp < 100:
		return 100
	case xp < 300:
		return 300
	case xp < 800:
		return 800
	case xp < 2000:
		return 2000
	case xp < 5000:
		return 5000
	default:
		return xp
	}
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}
