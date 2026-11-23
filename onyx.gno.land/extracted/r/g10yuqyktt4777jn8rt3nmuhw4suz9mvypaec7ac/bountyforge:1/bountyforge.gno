// Package bountyforge implements a trustless on-chain micro-bounty escrow,
// overflow-proof multi-contributor basis-point payout splitter, sponsor-safe
// crowdfunding with pro-rata refunds, arbiter dispute resolution with timeout
// escape hatch, DAO-composable canonical-banker entrypoints, and verifiable
// builder reputation on Gno.land.
package bountyforge

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"math"
	"math/overflow"
	"strconv"
	"strings"
	"unicode/utf8"

	"gno.land/p/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/escrowmath"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	StatusOpen      = "OPEN"
	StatusPaid      = "PAID"
	StatusCancelled = "CANCELLED"
	StatusDisputed  = "DISPUTED"

	MinRewardUgnot       int64 = 1000  // 0.001 GNOT minimum to prevent dust spam
	ReviewGraceBlocks    int64 = 500   // review/dispute window after DeadlineH before creator can cancel
	DisputeTimeoutBlocks int64 = 20000 // timeout escape hatch if designated arbiter disappears
	MinDisputeWinBps     int64 = 2500  // minimum 25% dispute award to earn full completion credit & XP

	MaxTitleRunes    = 120
	MaxSummaryRunes  = 1000
	MaxTagsRunes     = 120
	MaxProofURLRunes = 300
	MaxNotesRunes    = 400
	MaxSubmissions   = 50
	MaxSponsors      = 50
	MaxPageSize      = 25
	DefaultPageSize  = 15
)

// Contribution records an individual sponsor's (or creator's) escrowed ugnot deposit.
// Index 0 is always the bounty creator; additional indices are crowdfund sponsors.
type Contribution struct {
	Sponsor address
	Amount  int64
}

// Submission represents a contributor's proof-of-work entry for a bounty.
type Submission struct {
	Index      int
	Builder    address
	ProofURL   string
	Notes      string
	SubmittedH int64
	ViaSession bool
	Withdrawn  bool
}

// PayoutRecord tracks a single on-chain disbursement made from a bounty.
type PayoutRecord struct {
	Recipient address
	Amount    int64
	Bps       int64
}

// RefundRecord tracks a sponsor/creator refund returned on cancel or dispute settlement.
type RefundRecord struct {
	Sponsor address
	Amount  int64
}

// Bounty holds all escrow, sponsor, submission, dispute, and settlement state.
type Bounty struct {
	ID             uint64
	Title          string
	Summary        string
	Tags           string
	Creator        address
	Arbiter        address // optional; empty if no arbiter configured
	RewardUgnot    int64
	Status         string
	CreatedHeight  int64
	DeadlineH      int64 // 0 means no submission deadline
	DisputeReason  string
	DisputeOpenedH int64
	DisputeBy      address
	Contributions  []*Contribution
	Submissions    []*Submission
	Payouts        []*PayoutRecord
	Refunds        []*RefundRecord
}

// BuilderProfile stores cumulative on-chain reputation and earnings.
type BuilderProfile struct {
	Address     address
	Completed   int
	TotalEarned int64
	XP          int64
	LastHeight  int64
	creators    *avl.Tree // distinct bounty creators who paid this builder
}

// UniqueCreators returns the count of distinct creators who settled payouts to this builder.
func (p *BuilderProfile) UniqueCreators() int {
	if p == nil || p.creators == nil {
		return 0
	}
	return p.creators.Size()
}

var (
	nextID            seqid.ID
	bounties          *avl.Tree // key: seqid.ID.String() -> *Bounty
	openBounties      *avl.Tree // status index: OPEN
	paidBounties      *avl.Tree // status index: PAID
	disputedBounties  *avl.Tree // status index: DISPUTED
	cancelledBounties *avl.Tree // status index: CANCELLED
	builders          *avl.Tree // key: address.String() -> *BuilderProfile
	leaderboard       *avl.Tree // key: leaderboardKey(XP, TotalEarned, Addr) -> *BuilderProfile

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
	openBounties = avl.NewTree()
	paidBounties = avl.NewTree()
	disputedBounties = avl.NewTree()
	cancelledBounties = avl.NewTree()
	builders = avl.NewTree()
	leaderboard = avl.NewTree()

	totalEscrowed = 0
	totalPaidOut = 0
	openCount = 0
	paidCount = 0
	disputedCount = 0
	cancelledCnt = 0
	initRouter()
}

// ---------------------------------------------------------------------------
// Internal security, arithmetic, indexing, and validation helpers
// ---------------------------------------------------------------------------

func requireLiveRealm(cur realm) {
	if !cur.IsCurrent() {
		panic("bountyforge: invalid or stale realm context")
	}
}

// requireDirectUserRealm guards entrypoints that inspect unsafe.OriginSend().
// Callers MUST invoke runtime.AssertOriginCall() directly at the top of the
// exported MsgCall function (not inside a helper) so frame-depth verification passes.
func requireDirectUserRealm(cur realm) address {
	requireLiveRealm(cur)
	if !cur.Previous().IsUserCall() {
		panic("bountyforge: only direct user calls (maketx call) are accepted for OriginSend deposits")
	}
	return cur.Previous().Address()
}

// requireCaller authenticates either a direct EOA or a calling realm (such as a Gno DAO)
// strictly via the live crossing frame's immediate caller (never tx.origin).
func requireCaller(cur realm) address {
	requireLiveRealm(cur)
	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("bountyforge: invalid caller address")
	}
	return caller
}

func strictUgnotFromOriginSend() int64 {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("bountyforge: transaction must attach strictly positive ugnot only")
	}
	return sent[0].Amount
}

func mustAdd64(a, b int64, ctx string) int64 {
	sum, ok := overflow.Add64(a, b)
	if !ok {
		panic("bountyforge: int64 overflow in " + ctx)
	}
	return sum
}

func mustSub64(a, b int64, ctx string) int64 {
	diff, ok := overflow.Sub64(a, b)
	if !ok || diff < 0 {
		panic("bountyforge: int64 underflow in " + ctx)
	}
	return diff
}

func cleanStoredText(raw string, maxRunes int, multiline bool) string {
	s := sanitize.NormalizeBreaks(raw)
	s = sanitize.StripBidiAndZeroWidth(s)
	s = strings.ReplaceAll(s, "\x00", "\uFFFD")
	if !multiline {
		s = strings.ReplaceAll(s, "\n", " ")
		s = strings.ReplaceAll(s, "\t", " ")
	}
	s = strings.TrimSpace(s)
	if maxRunes > 0 && utf8.RuneCountInString(s) > maxRunes {
		panic(ufmt.Sprintf("bountyforge: text exceeds maximum length of %d characters", maxRunes))
	}
	return s
}

func validateProofURL(raw string) string {
	u := cleanStoredText(raw, MaxProofURLRunes, false)
	if u == "" {
		panic("bountyforge: proofURL cannot be empty")
	}
	lower := strings.ToLower(u)
	if !strings.HasPrefix(lower, "https://") && !strings.HasPrefix(lower, "http://") {
		panic("bountyforge: proofURL must start with https:// or http://")
	}
	if sanitize.URL(u) == "" {
		panic("bountyforge: proofURL failed URL safety validation")
	}
	return u
}

func statusTree(status string) *avl.Tree {
	switch status {
	case StatusOpen:
		return openBounties
	case StatusPaid:
		return paidBounties
	case StatusDisputed:
		return disputedBounties
	case StatusCancelled:
		return cancelledBounties
	default:
		return nil
	}
}

func moveBountyStatus(b *Bounty, oldStatus, newStatus string) {
	key := seqid.ID(b.ID).String()
	if oldTree := statusTree(oldStatus); oldTree != nil {
		oldTree.Remove(key)
	}
	b.Status = newStatus
	if newTree := statusTree(newStatus); newTree != nil {
		newTree.Set(key, b)
	}
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

func (b *Bounty) activeSubmissionCount() int {
	n := 0
	for _, s := range b.Submissions {
		if !s.Withdrawn {
			n++
		}
	}
	return n
}

func (b *Bounty) hasContributor(addr address) bool {
	for _, c := range b.Contributions {
		if c.Sponsor == addr {
			return true
		}
	}
	return false
}

func (b *Bounty) depositAmounts() []int64 {
	out := make([]int64, len(b.Contributions))
	for i, c := range b.Contributions {
		out[i] = c.Amount
	}
	return out
}

func padUint64(v uint64, width int) string {
	s := strconv.FormatUint(v, 10)
	if len(s) >= width {
		return s
	}
	var b strings.Builder
	b.Grow(width)
	for i := len(s); i < width; i++ {
		b.WriteByte('0')
	}
	b.WriteString(s)
	return b.String()
}

// leaderboardKey orders builders deterministically in ascending AVL traversal:
// XP DESC, TotalEarned DESC, Address ASC — O(log N) updates, O(pageSize) renders.
func leaderboardKey(xp, earned int64, addr address) string {
	if xp < 0 {
		xp = 0
	}
	if earned < 0 {
		earned = 0
	}
	invXP := uint64(math.MaxInt64 - xp)
	invEarned := uint64(math.MaxInt64 - earned)
	return padUint64(invXP, 19) + ":" + padUint64(invEarned, 19) + ":" + addr.String()
}

func creditBuilder(addr address, creator address, ugnot int64, height int64, awardCompletion bool) {
	if ugnot <= 0 {
		panic("bountyforge: cannot credit non-positive builder payout")
	}
	key := addr.String()
	var prof *BuilderProfile
	var oldKey string
	if raw := builders.Get(key); raw != nil {
		prof = raw.(*BuilderProfile)
		oldKey = leaderboardKey(prof.XP, prof.TotalEarned, prof.Address)
	} else {
		prof = &BuilderProfile{
			Address:  addr,
			creators: avl.NewTree(),
		}
	}
	if oldKey != "" {
		leaderboard.Remove(oldKey)
	}

	prof.TotalEarned = mustAdd64(prof.TotalEarned, ugnot, "builder total earned")
	if awardCompletion {
		prof.Completed++
		prof.XP = mustAdd64(prof.XP, escrowmath.ComputeXP(ugnot), "builder XP")
		if creator.IsValid() {
			prof.creators.Set(creator.String(), true)
		}
	}
	prof.LastHeight = height
	builders.Set(key, prof)
	leaderboard.Set(leaderboardKey(prof.XP, prof.TotalEarned, prof.Address), prof)
}

func releaseFunds(cur realm, recipient address, ugnot int64) {
	if ugnot <= 0 {
		panic("bountyforge: payout amount must be strictly positive")
	}
	if !recipient.IsValid() {
		panic("bountyforge: invalid recipient address")
	}
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if b.GetCoin(realmAddr, "ugnot") < ugnot {
		panic("bountyforge: insufficient realm balance for payout")
	}
	b.SendCoins(realmAddr, recipient, chain.Coins{chain.NewCoin("ugnot", ugnot)})
}

func parseIntList(csv string) []int {
	trimmed := strings.TrimSpace(csv)
	if trimmed == "" {
		panic("bountyforge: empty integer CSV")
	}
	parts := strings.Split(trimmed, ",")
	if len(parts) > MaxSubmissions {
		panic("bountyforge: too many entries in CSV")
	}
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
	trimmed := strings.TrimSpace(csv)
	if trimmed == "" {
		panic("bountyforge: empty int64 CSV")
	}
	parts := strings.Split(trimmed, ",")
	if len(parts) > MaxSubmissions {
		panic("bountyforge: too many entries in CSV")
	}
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

func createBountyCore(cur realm, caller address, amt int64, title, summary, tags, arbiterStr string, deadlineBlocks int64) uint64 {
	cleanTitle := cleanStoredText(title, MaxTitleRunes, false)
	if cleanTitle == "" {
		panic("bountyforge: title cannot be empty")
	}
	cleanSummary := cleanStoredText(summary, MaxSummaryRunes, true)
	if cleanSummary == "" {
		panic("bountyforge: summary cannot be empty")
	}
	cleanTags := cleanStoredText(tags, MaxTagsRunes, false)
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

	if amt < MinRewardUgnot {
		panic(ufmt.Sprintf("bountyforge: reward must be at least %d ugnot", MinRewardUgnot))
	}

	newTotalEscrowed := mustAdd64(totalEscrowed, amt, "totalEscrowed")

	// Enforce solvency invariant: realm balance must cover all existing escrow + new deposit.
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if b.GetCoin(realmAddr, "ugnot") < newTotalEscrowed {
		panic("bountyforge: realm balance did not receive declared ugnot deposit")
	}

	height := runtime.ChainHeight()
	var deadlineH int64
	if deadlineBlocks > 0 {
		deadlineH = mustAdd64(height, deadlineBlocks, "deadlineH")
		// Ensure deadlineH + ReviewGraceBlocks can never overflow later.
		_ = mustAdd64(deadlineH, ReviewGraceBlocks, "review grace deadline")
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
		Contributions: []*Contribution{
			{Sponsor: caller, Amount: amt},
		},
	}

	key := id.String()
	bounties.Set(key, bounty)
	openBounties.Set(key, bounty)
	totalEscrowed = newTotalEscrowed
	openCount++

	chain.Emit(
		"BountyCreated",
		"id", strconv.FormatUint(bounty.ID, 10),
		"creator", caller.String(),
		"reward_ugnot", strconv.FormatInt(amt, 10),
		"arbiter", arbiter.String(),
		"deadline_height", strconv.FormatInt(deadlineH, 10),
	)
	return bounty.ID
}

func topUpBountyCore(cur realm, caller address, bountyID uint64, amt int64) int64 {
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusOpen {
		panic("bountyforge: can only top up an OPEN bounty")
	}
	if bounty.DeadlineH > 0 && runtime.ChainHeight() > bounty.DeadlineH {
		panic("bountyforge: cannot top up after submission deadline has passed")
	}
	if amt <= 0 {
		panic("bountyforge: top-up amount must be positive")
	}

	newTotalEscrowed := mustAdd64(totalEscrowed, amt, "totalEscrowed")
	newReward := mustAdd64(bounty.RewardUgnot, amt, "bounty reward")

	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if b.GetCoin(realmAddr, "ugnot") < newTotalEscrowed {
		panic("bountyforge: realm balance did not receive top-up ugnot")
	}

	// Track per-sponsor contribution so refunds never hand sponsor funds to the creator.
	updated := false
	for _, c := range bounty.Contributions {
		if c.Sponsor == caller {
			c.Amount = mustAdd64(c.Amount, amt, "sponsor contribution")
			updated = true
			break
		}
	}
	if !updated {
		if len(bounty.Contributions) >= MaxSponsors {
			panic("bountyforge: maximum sponsors reached for this bounty")
		}
		bounty.Contributions = append(bounty.Contributions, &Contribution{
			Sponsor: caller,
			Amount:  amt,
		})
	}

	bounty.RewardUgnot = newReward
	totalEscrowed = newTotalEscrowed

	chain.Emit(
		"BountyToppedUp",
		"id", strconv.FormatUint(bounty.ID, 10),
		"sponsor", caller.String(),
		"added_ugnot", strconv.FormatInt(amt, 10),
		"new_reward_ugnot", strconv.FormatInt(bounty.RewardUgnot, 10),
	)
	return bounty.RewardUgnot
}

// ---------------------------------------------------------------------------
// Public Realm Transactions
// ---------------------------------------------------------------------------

// CreateBounty locks attached ugnot into on-chain escrow and opens a new bounty.
// arbiterStr may be empty if no third-party dispute arbiter is needed.
// deadlineBlocks sets submission expiry relative to current block height (0 = no expiry).
func CreateBounty(cur realm, title, summary, tags, arbiterStr string, deadlineBlocks int64) uint64 {
	runtime.AssertOriginCall()
	caller := requireDirectUserRealm(cur)
	amt := strictUgnotFromOriginSend()
	return createBountyCore(cur, caller, amt, title, summary, tags, arbiterStr, deadlineBlocks)
}

// CreateBountyWithBanker enables Gno DAOs and composable realms to fund bounties
// atomically using a canonical Banker (defending Gno Security Threat Class 3).
func CreateBountyWithBanker(cur realm, payerBanker banker.Banker, amt int64, title, summary, tags, arbiterStr string, deadlineBlocks int64) uint64 {
	caller := requireCaller(cur)
	if !banker.IsCanonical(payerBanker) {
		panic("bountyforge: non-canonical banker rejected")
	}
	if amt < MinRewardUgnot {
		panic(ufmt.Sprintf("bountyforge: reward must be at least %d ugnot", MinRewardUgnot))
	}
	payerBanker.SendCoins(caller, cur.Address(), chain.Coins{chain.NewCoin("ugnot", amt)})
	return createBountyCore(cur, caller, amt, title, summary, tags, arbiterStr, deadlineBlocks)
}

// TopUpBounty allows any direct EOA sponsor to add extra ugnot to an active OPEN bounty.
func TopUpBounty(cur realm, bountyID uint64) int64 {
	runtime.AssertOriginCall()
	caller := requireDirectUserRealm(cur)
	amt := strictUgnotFromOriginSend()
	return topUpBountyCore(cur, caller, bountyID, amt)
}

// TopUpBountyWithBanker enables DAOs and realms to crowdfund an OPEN bounty via a canonical Banker.
func TopUpBountyWithBanker(cur realm, payerBanker banker.Banker, bountyID uint64, amt int64) int64 {
	caller := requireCaller(cur)
	if !banker.IsCanonical(payerBanker) {
		panic("bountyforge: non-canonical banker rejected")
	}
	if amt <= 0 {
		panic("bountyforge: top-up amount must be positive")
	}
	payerBanker.SendCoins(caller, cur.Address(), chain.Coins{chain.NewCoin("ugnot", amt)})
	return topUpBountyCore(cur, caller, bountyID, amt)
}

// SubmitWork registers (or updates) a builder's deliverable proof URL and notes on an OPEN bounty.
// Supports both human EOAs and Gno v1.8.0 scoped session keys for AI agents.
func SubmitWork(cur realm, bountyID uint64, proofURL, notes string) int {
	caller := requireCaller(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusOpen {
		panic("bountyforge: submissions are only accepted on OPEN bounties")
	}
	if bounty.DeadlineH > 0 && runtime.ChainHeight() > bounty.DeadlineH {
		panic("bountyforge: submission deadline has passed")
	}
	if caller == bounty.Creator {
		panic("bountyforge: bounty creator cannot submit work to their own bounty")
	}
	if bounty.Arbiter != "" && caller == bounty.Arbiter {
		panic("bountyforge: bounty arbiter cannot submit work")
	}

	cleanProof := validateProofURL(proofURL)
	cleanNotes := cleanStoredText(notes, MaxNotesRunes, false)
	_, _, _, isSession := runtime.GetSessionInfo()

	// Allow updating (or reactivating) an existing submission from the same builder.
	for _, sub := range bounty.Submissions {
		if sub.Builder == caller {
			sub.ProofURL = cleanProof
			sub.Notes = cleanNotes
			sub.SubmittedH = runtime.ChainHeight()
			sub.ViaSession = isSession
			sub.Withdrawn = false
			chain.Emit(
				"WorkUpdated",
				"id", strconv.FormatUint(bounty.ID, 10),
				"builder", caller.String(),
				"index", strconv.Itoa(sub.Index),
				"via_session", strconv.FormatBool(isSession),
			)
			return sub.Index
		}
	}

	if len(bounty.Submissions) >= MaxSubmissions {
		panic("bountyforge: maximum submissions reached for this bounty")
	}

	idx := len(bounty.Submissions)
	bounty.Submissions = append(bounty.Submissions, &Submission{
		Index:      idx,
		Builder:    caller,
		ProofURL:   cleanProof,
		Notes:      cleanNotes,
		SubmittedH: runtime.ChainHeight(),
		ViaSession: isSession,
	})

	chain.Emit(
		"WorkSubmitted",
		"id", strconv.FormatUint(bounty.ID, 10),
		"builder", caller.String(),
		"index", strconv.Itoa(idx),
		"via_session", strconv.FormatBool(isSession),
	)
	return idx
}

// WithdrawSubmission allows a builder to retract their submission while the bounty is OPEN.
// Indices remain immutable to prevent submissionIdx front-running.
func WithdrawSubmission(cur realm, bountyID uint64) {
	caller := requireCaller(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusOpen {
		panic("bountyforge: can only withdraw submission on OPEN bounties")
	}
	for _, sub := range bounty.Submissions {
		if sub.Builder == caller && !sub.Withdrawn {
			sub.Withdrawn = true
			chain.Emit(
				"WorkWithdrawn",
				"id", strconv.FormatUint(bounty.ID, 10),
				"builder", caller.String(),
				"index", strconv.Itoa(sub.Index),
			)
			return
		}
	}
	panic("bountyforge: no active submission found for caller")
}

// ApproveAndPay releases 100% of a bounty's escrowed ugnot to the winning builder.
func ApproveAndPay(cur realm, bountyID uint64, submissionIdx int) {
	caller := requireCaller(cur)
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
	sub := bounty.Submissions[submissionIdx]
	if sub.Withdrawn {
		panic("bountyforge: cannot pay a withdrawn submission")
	}

	winner := sub.Builder
	amount := bounty.RewardUgnot

	// Effects before interactions (CEI pattern).
	moveBountyStatus(bounty, StatusOpen, StatusPaid)
	bounty.Payouts = []*PayoutRecord{
		{Recipient: winner, Amount: amount, Bps: escrowmath.TotalBPS},
	}
	totalEscrowed = mustSub64(totalEscrowed, amount, "totalEscrowed")
	totalPaidOut = mustAdd64(totalPaidOut, amount, "totalPaidOut")
	openCount--
	paidCount++
	creditBuilder(winner, bounty.Creator, amount, runtime.ChainHeight(), true)

	releaseFunds(cur, winner, amount)

	chain.Emit(
		"BountyPaid",
		"id", strconv.FormatUint(bounty.ID, 10),
		"winner", winner.String(),
		"amount_ugnot", strconv.FormatInt(amount, 10),
	)
}

// SplitAndPay splits a bounty's escrow across multiple contributors using exact
// overflow-proof, dust-conserving basis points (each weight 1..10000, sum == 10000,
// every resulting share strictly > 0 ugnot).
func SplitAndPay(cur realm, bountyID uint64, indicesCSV, bpsCSV string) {
	caller := requireCaller(cur)
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
		if bounty.Submissions[idx].Withdrawn {
			panic("bountyforge: cannot split payout to a withdrawn submission")
		}
		seen[idx] = true
		recipients[i] = bounty.Submissions[idx].Builder
	}

	shares, err := escrowmath.SplitBasisPoints(bounty.RewardUgnot, bps)
	if err != nil {
		panic(err.Error())
	}

	amount := bounty.RewardUgnot
	var shareSum int64
	for _, s := range shares {
		if s <= 0 {
			panic("bountyforge: split produced non-positive share")
		}
		shareSum = mustAdd64(shareSum, s, "split share sum")
	}
	if shareSum != amount {
		panic("bountyforge: split conservation invariant violated")
	}

	height := runtime.ChainHeight()

	// Effects before interactions (CEI pattern).
	moveBountyStatus(bounty, StatusOpen, StatusPaid)
	bounty.Payouts = make([]*PayoutRecord, len(recipients))
	for i, rec := range recipients {
		bounty.Payouts[i] = &PayoutRecord{
			Recipient: rec,
			Amount:    shares[i],
			Bps:       bps[i],
		}
		creditBuilder(rec, bounty.Creator, shares[i], height, true)
	}
	totalEscrowed = mustSub64(totalEscrowed, amount, "totalEscrowed")
	totalPaidOut = mustAdd64(totalPaidOut, amount, "totalPaidOut")
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

// CancelAndRefund cancels an OPEN bounty and refunds EVERY contributor (creator +
// all crowdfund sponsors) their exact deposited ugnot.
// Allowed if there are zero active submissions, OR after DeadlineH + ReviewGraceBlocks.
func CancelAndRefund(cur realm, bountyID uint64) {
	caller := requireCaller(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if caller != bounty.Creator {
		panic("bountyforge: only the bounty creator can cancel")
	}
	if bounty.Status != StatusOpen {
		panic("bountyforge: only OPEN bounties can be cancelled")
	}
	if bounty.activeSubmissionCount() > 0 {
		if bounty.DeadlineH == 0 {
			panic("bountyforge: cannot cancel while submissions exist before deadline")
		}
		cancelAfter := mustAdd64(bounty.DeadlineH, ReviewGraceBlocks, "review grace deadline")
		if runtime.ChainHeight() <= cancelAfter {
			panic("bountyforge: cannot cancel while submissions exist before deadline + review grace")
		}
	}

	refundTotal := bounty.RewardUgnot
	refundRecords := make([]*RefundRecord, len(bounty.Contributions))
	var verifySum int64
	for i, c := range bounty.Contributions {
		refundRecords[i] = &RefundRecord{Sponsor: c.Sponsor, Amount: c.Amount}
		verifySum = mustAdd64(verifySum, c.Amount, "cancel refund sum")
	}
	if verifySum != refundTotal {
		panic("bountyforge: sponsor ledger mismatch")
	}

	// Effects before interactions (CEI pattern).
	moveBountyStatus(bounty, StatusOpen, StatusCancelled)
	bounty.Refunds = refundRecords
	totalEscrowed = mustSub64(totalEscrowed, refundTotal, "totalEscrowed")
	openCount--
	cancelledCnt++

	for _, r := range refundRecords {
		releaseFunds(cur, r.Sponsor, r.Amount)
	}

	chain.Emit(
		"BountyCancelled",
		"id", strconv.FormatUint(bounty.ID, 10),
		"creator", bounty.Creator.String(),
		"refund_ugnot", strconv.FormatInt(refundTotal, 10),
		"sponsors_refunded", strconv.Itoa(len(refundRecords)),
	)
}

// OpenDispute freezes an OPEN bounty with a configured arbiter for resolution.
// Either the creator or any builder with an active submission may open a dispute.
func OpenDispute(cur realm, bountyID uint64, reason string) {
	caller := requireCaller(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusOpen {
		panic("bountyforge: only OPEN bounties can enter dispute")
	}
	if bounty.Arbiter == "" {
		panic("bountyforge: bounty has no arbiter configured")
	}
	if bounty.activeSubmissionCount() == 0 {
		panic("bountyforge: cannot dispute a bounty with zero active submissions")
	}

	authorized := caller == bounty.Creator
	if !authorized {
		for _, sub := range bounty.Submissions {
			if sub.Builder == caller && !sub.Withdrawn {
				authorized = true
				break
			}
		}
	}
	if !authorized {
		panic("bountyforge: only creator or an active submitter can open a dispute")
	}

	cleanReason := cleanStoredText(reason, MaxNotesRunes, true)
	if cleanReason == "" {
		panic("bountyforge: dispute reason cannot be empty")
	}

	moveBountyStatus(bounty, StatusOpen, StatusDisputed)
	bounty.DisputeReason = cleanReason
	bounty.DisputeOpenedH = runtime.ChainHeight()
	bounty.DisputeBy = caller
	openCount--
	disputedCount++

	chain.Emit(
		"DisputeOpened",
		"id", strconv.FormatUint(bounty.ID, 10),
		"opened_by", caller.String(),
		"arbiter", bounty.Arbiter.String(),
		"opened_height", strconv.FormatInt(bounty.DisputeOpenedH, 10),
	)
}

// ResolveDispute allows the designated arbiter to settle a DISPUTED bounty by
// awarding builderBps (0..10000) to the selected submitter and refunding the
// remaining pool pro-rata across ALL contributors (creator + crowdfund sponsors).
func ResolveDispute(cur realm, bountyID uint64, submissionIdx int, builderBps int64) {
	caller := requireCaller(cur)
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

	var builder address
	if builderBps > 0 {
		if submissionIdx < 0 || submissionIdx >= len(bounty.Submissions) {
			panic("bountyforge: submission index out of range")
		}
		sub := bounty.Submissions[submissionIdx]
		if sub.Withdrawn {
			panic("bountyforge: cannot award dispute to a withdrawn submission")
		}
		builder = sub.Builder
	}

	total := bounty.RewardUgnot
	var builderShare, refundPool int64

	switch builderBps {
	case 0:
		refundPool = total
	case escrowmath.TotalBPS:
		builderShare = total
	default:
		shares, err := escrowmath.SplitBasisPoints(total, []int64{builderBps, escrowmath.TotalBPS - builderBps})
		if err != nil {
			panic(err.Error())
		}
		builderShare = shares[0]
		refundPool = shares[1]
	}

	var refundRecords []*RefundRecord
	if refundPool > 0 {
		sponsorRefunds, err := escrowmath.ProRataRefund(refundPool, bounty.depositAmounts())
		if err != nil {
			panic(err.Error())
		}
		for i, amt := range sponsorRefunds {
			if amt > 0 {
				refundRecords = append(refundRecords, &RefundRecord{
					Sponsor: bounty.Contributions[i].Sponsor,
					Amount:  amt,
				})
			}
		}
	}

	// Effects before interactions (CEI pattern).
	totalEscrowed = mustSub64(totalEscrowed, total, "totalEscrowed")
	disputedCount--
	bounty.Refunds = refundRecords

	if builderShare > 0 {
		moveBountyStatus(bounty, StatusDisputed, StatusPaid)
		paidCount++
		totalPaidOut = mustAdd64(totalPaidOut, builderShare, "totalPaidOut")
		bounty.Payouts = []*PayoutRecord{
			{Recipient: builder, Amount: builderShare, Bps: builderBps},
		}
		creditBuilder(builder, bounty.Creator, builderShare, runtime.ChainHeight(), builderBps >= MinDisputeWinBps)
	} else {
		moveBountyStatus(bounty, StatusDisputed, StatusCancelled)
		cancelledCnt++
	}

	if builderShare > 0 {
		releaseFunds(cur, builder, builderShare)
	}
	for _, r := range refundRecords {
		releaseFunds(cur, r.Sponsor, r.Amount)
	}

	chain.Emit(
		"DisputeResolved",
		"id", strconv.FormatUint(bounty.ID, 10),
		"arbiter", caller.String(),
		"builder_ugnot", strconv.FormatInt(builderShare, 10),
		"refund_pool_ugnot", strconv.FormatInt(refundPool, 10),
	)
}

// ExpireDispute is an escape hatch preventing permanent fund lock if an arbiter
// becomes unresponsive for more than DisputeTimeoutBlocks. Any contributor or
// active submitter can trigger exact refunds back to all contributors.
func ExpireDispute(cur realm, bountyID uint64) {
	caller := requireCaller(cur)
	bounty, _ := getBountyByUint64(bountyID)
	if bounty.Status != StatusDisputed {
		panic("bountyforge: bounty is not DISPUTED")
	}

	authorized := bounty.hasContributor(caller)
	if !authorized {
		for _, sub := range bounty.Submissions {
			if sub.Builder == caller && !sub.Withdrawn {
				authorized = true
				break
			}
		}
	}
	if !authorized {
		panic("bountyforge: only a contributor or active submitter can expire a timed-out dispute")
	}

	expireAt := mustAdd64(bounty.DisputeOpenedH, DisputeTimeoutBlocks, "dispute timeout")
	if runtime.ChainHeight() <= expireAt {
		panic("bountyforge: dispute has not timed out yet")
	}

	refundTotal := bounty.RewardUgnot
	refundRecords := make([]*RefundRecord, len(bounty.Contributions))
	for i, c := range bounty.Contributions {
		refundRecords[i] = &RefundRecord{Sponsor: c.Sponsor, Amount: c.Amount}
	}

	// Effects before interactions (CEI pattern).
	moveBountyStatus(bounty, StatusDisputed, StatusCancelled)
	bounty.Refunds = refundRecords
	totalEscrowed = mustSub64(totalEscrowed, refundTotal, "totalEscrowed")
	disputedCount--
	cancelledCnt++

	for _, r := range refundRecords {
		releaseFunds(cur, r.Sponsor, r.Amount)
	}

	chain.Emit(
		"DisputeExpired",
		"id", strconv.FormatUint(bounty.ID, 10),
		"triggered_by", caller.String(),
		"refund_ugnot", strconv.FormatInt(refundTotal, 10),
	)
}
