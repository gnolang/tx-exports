// Package tavern implements the Gnome Tavern Quests & Verifiable Escrow Realm on Gno.land.
// Sponsors lock ugnot bounties into realm escrow with deterministic deadline and arbitration
// invariants; guild builders claim quests, submit 64-hex SHA-256 proof digests, and settle
// payouts without double-spend or off-chain custodians.
package tavern

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const (
	DenomUgnot = "ugnot"

	StatusOpen      = "OPEN"
	StatusClaimed   = "CLAIMED"
	StatusSubmitted = "SUBMITTED"
	StatusDisputed  = "DISPUTED"
	StatusSettled   = "SETTLED"
	StatusRefunded  = "REFUNDED"
)

// Quest represents an escrowed work order tracked deterministically on-chain.
type Quest struct {
	ID                 uint64
	Title              string
	SpecHash           string
	AcceptanceCriteria string
	Sponsor            address
	Arbitrator         address
	Worker             address
	BountyUgnot        int64
	CreatedHeight      int64
	DeadlineHeight     int64
	Status             string
	WorkerNote         string
	ProofSHA256        string
	ProofURI           string
	DisputeReason      string
}

// GuildStats tracks verified on-chain settlement history per builder address.
type GuildStats struct {
	Address     address
	Completed   uint64
	DisputesWon uint64
	EarnedUgnot int64
}

var (
	nextQuestID uint64
	quests      []*Quest
	guildBoard  []*GuildStats
	totalLocked int64
	totalPaid   int64
)

func resetStateForTests() {
	nextQuestID = 0
	quests = nil
	guildBoard = nil
	totalLocked = 0
	totalPaid = 0
}

func isSafeProofURI(uri string) bool {
	if strings.ContainsAny(uri, "\r\n\t ") {
		return false
	}
	lower := strings.ToLower(uri)
	return strings.HasPrefix(lower, "https://") ||
		strings.HasPrefix(lower, "ipfs://") ||
		strings.HasPrefix(lower, "ar://") ||
		strings.HasPrefix(lower, "gno.land/")
}

func sanitizeMarkdownCell(s string) string {
	r := strings.NewReplacer("|", "/", "\r", " ", "\n", " ")
	return strings.TrimSpace(r.Replace(s))
}

func isValidHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		isDigit := c >= '0' && c <= '9'
		isHex := c >= 'a' && c <= 'f'
		if !isDigit && !isHex {
			return false
		}
	}
	return true
}

func findQuest(questID uint64) *Quest {
	if questID == 0 || questID > uint64(len(quests)) {
		panic("quest not found")
	}
	q := quests[questID-1]
	if q == nil || q.ID != questID {
		panic("quest index mismatch")
	}
	return q
}

func recordGuildPayout(worker address, amount int64, viaDispute bool) {
	for i := 0; i < len(guildBoard); i++ {
		if guildBoard[i].Address == worker {
			guildBoard[i].Completed++
			if viaDispute {
				guildBoard[i].DisputesWon++
			}
			guildBoard[i].EarnedUgnot += amount
			return
		}
	}
	var dw uint64
	if viaDispute {
		dw = 1
	}
	guildBoard = append(guildBoard, &GuildStats{
		Address:     worker,
		Completed:   1,
		DisputesWon: dw,
		EarnedUgnot: amount,
	})
}

// PostQuest locks the caller's sent ugnot into realm escrow and opens a new quest.
func PostQuest(
	cur realm,
	title string,
	specHash string,
	acceptanceCriteria string,
	arbitrator address,
	deadlineHeight int64,
) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls accepted")
	}
	title = strings.TrimSpace(title)
	if title == "" {
		panic("title must be non-empty")
	}
	if !isValidHex64(specHash) {
		panic("specHash must be 64 lowercase hex characters")
	}
	if strings.TrimSpace(acceptanceCriteria) == "" {
		panic("acceptanceCriteria must be non-empty")
	}
	if arbitrator == "" || !arbitrator.IsValid() {
		panic("arbitrator address must be valid bech32")
	}
	if arbitrator == cur.Address() {
		panic("arbitrator cannot be realm address")
	}

	nowHeight := runtime.ChainHeight()
	if deadlineHeight <= nowHeight {
		panic("deadlineHeight must be strictly greater than current chain height")
	}

	sent := unsafe.OriginSend()
	bounty := sent.AmountOf(DenomUgnot)
	if bounty <= 0 {
		panic("must attach positive ugnot bounty")
	}

	sponsor := cur.Previous().Address()
	if sponsor == arbitrator {
		panic("arbitrator must be distinct from sponsor")
	}

	nextQuestID++
	q := &Quest{
		ID:                 nextQuestID,
		Title:              title,
		SpecHash:           specHash,
		AcceptanceCriteria: strings.TrimSpace(acceptanceCriteria),
		Sponsor:            sponsor,
		Arbitrator:         arbitrator,
		BountyUgnot:        bounty,
		CreatedHeight:      nowHeight,
		DeadlineHeight:     deadlineHeight,
		Status:             StatusOpen,
	}
	quests = append(quests, q)
	totalLocked += bounty

	chain.Emit(
		"QuestPosted",
		"quest_id", strconv.FormatUint(q.ID, 10),
		"sponsor", string(sponsor),
		"bounty_ugnot", strconv.FormatInt(bounty, 10),
	)
	return q.ID
}

// ClaimQuest assigns an OPEN quest to the calling guild worker.
func ClaimQuest(cur realm, questID uint64, workerNote string) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls accepted")
	}
	q := findQuest(questID)
	if q.Status != StatusOpen {
		panic("quest is not open")
	}
	if runtime.ChainHeight() > q.DeadlineHeight {
		panic("quest deadline has passed")
	}
	caller := cur.Previous().Address()
	if caller == q.Sponsor {
		panic("sponsor cannot claim own quest")
	}
	if caller == q.Arbitrator {
		panic("arbitrator cannot claim quest")
	}

	q.Worker = caller
	q.WorkerNote = strings.TrimSpace(workerNote)
	q.Status = StatusClaimed

	chain.Emit(
		"QuestClaimed",
		"quest_id", strconv.FormatUint(q.ID, 10),
		"worker", string(caller),
	)
}

// SubmitProof attaches a verifiable 64-hex SHA-256 artifact digest and proof URI.
func SubmitProof(cur realm, questID uint64, artifactSHA256 string, proofURI string) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls accepted")
	}
	q := findQuest(questID)
	if q.Status != StatusClaimed {
		panic("quest is not claimed")
	}
	caller := cur.Previous().Address()
	if caller != q.Worker {
		panic("only assigned worker can submit proof")
	}
	if runtime.ChainHeight() > q.DeadlineHeight {
		panic("quest deadline has passed")
	}
	if !isValidHex64(artifactSHA256) {
		panic("artifactSHA256 must be 64 lowercase hex characters")
	}
	proofURI = strings.TrimSpace(proofURI)
	if !isSafeProofURI(proofURI) {
		panic("proofURI must use https://, ipfs://, ar://, or gno.land/ prefix")
	}

	q.ProofSHA256 = artifactSHA256
	q.ProofURI = proofURI
	q.Status = StatusSubmitted

	chain.Emit(
		"ProofSubmitted",
		"quest_id", strconv.FormatUint(q.ID, 10),
		"worker", string(caller),
		"sha256", artifactSHA256,
	)
}

// ApproveAndRelease lets the sponsor release escrowed ugnot to the worker after proof review.
func ApproveAndRelease(cur realm, questID uint64) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls accepted")
	}
	q := findQuest(questID)
	if q.Status != StatusSubmitted {
		panic("quest must be in SUBMITTED state to release")
	}
	caller := cur.Previous().Address()
	if caller != q.Sponsor {
		panic("only sponsor can approve and release")
	}

	// Checks-Effects-Interactions: update state before bank transfer.
	payout := q.BountyUgnot
	q.Status = StatusSettled
	totalLocked -= payout
	totalPaid += payout
	recordGuildPayout(q.Worker, payout, false)

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), q.Worker, chain.NewCoins(chain.NewCoin(DenomUgnot, payout)))

	chain.Emit(
		"QuestSettled",
		"quest_id", strconv.FormatUint(q.ID, 10),
		"worker", string(q.Worker),
		"bounty_ugnot", strconv.FormatInt(payout, 10),
	)
}

// OpenDispute lets either the sponsor or worker escalate a SUBMITTED quest to the arbitrator.
func OpenDispute(cur realm, questID uint64, reason string) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls accepted")
	}
	q := findQuest(questID)
	if q.Status != StatusSubmitted {
		panic("dispute requires SUBMITTED status")
	}
	caller := cur.Previous().Address()
	if caller != q.Sponsor && caller != q.Worker {
		panic("only sponsor or assigned worker can open dispute")
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		panic("dispute reason must be non-empty")
	}

	q.DisputeReason = reason
	q.Status = StatusDisputed

	chain.Emit(
		"QuestDisputed",
		"quest_id", strconv.FormatUint(q.ID, 10),
		"by", string(caller),
	)
}

// ResolveDispute lets the designated arbitrator settle a DISPUTED quest to worker or sponsor.
func ResolveDispute(cur realm, questID uint64, awardToWorker bool) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls accepted")
	}
	q := findQuest(questID)
	if q.Status != StatusDisputed {
		panic("quest is not in DISPUTED state")
	}
	caller := cur.Previous().Address()
	if caller != q.Arbitrator {
		panic("only designated arbitrator can resolve dispute")
	}

	amount := q.BountyUgnot
	totalLocked -= amount
	var recipient address
	if awardToWorker {
		q.Status = StatusSettled
		totalPaid += amount
		recipient = q.Worker
		recordGuildPayout(q.Worker, amount, true)
	} else {
		q.Status = StatusRefunded
		recipient = q.Sponsor
	}

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), recipient, chain.NewCoins(chain.NewCoin(DenomUgnot, amount)))

	chain.Emit(
		"DisputeResolved",
		"quest_id", strconv.FormatUint(q.ID, 10),
		"recipient", string(recipient),
		"amount_ugnot", strconv.FormatInt(amount, 10),
	)
}

// CancelExpired refunds escrowed ugnot to the sponsor once deadlineHeight passes without submission.
func CancelExpired(cur realm, questID uint64) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls accepted")
	}
	q := findQuest(questID)
	if q.Status != StatusOpen && q.Status != StatusClaimed {
		panic("only OPEN or CLAIMED quests can expire")
	}
	caller := cur.Previous().Address()
	if caller != q.Sponsor {
		panic("only sponsor can cancel expired quest")
	}
	if runtime.ChainHeight() <= q.DeadlineHeight {
		panic("quest has not expired yet")
	}

	refund := q.BountyUgnot
	q.Status = StatusRefunded
	totalLocked -= refund

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), q.Sponsor, chain.NewCoins(chain.NewCoin(DenomUgnot, refund)))

	chain.Emit(
		"QuestRefunded",
		"quest_id", strconv.FormatUint(q.ID, 10),
		"sponsor", string(q.Sponsor),
		"refund_ugnot", strconv.FormatInt(refund, 10),
	)
}

// TotalEscrowLocked returns the tracked total ugnot currently locked in active quests.
func TotalEscrowLocked() int64 {
	return totalLocked
}

// TotalSettledUgnot returns cumulative ugnot paid to guild builders.
func TotalSettledUgnot() int64 {
	return totalPaid
}

// QuestCount returns the total number of quests ever posted.
func QuestCount() uint64 {
	return nextQuestID
}

// ComputeActiveEscrowSum recomputes locked escrow directly from quest records for invariant checks.
func ComputeActiveEscrowSum() int64 {
	var sum int64
	for i := 0; i < len(quests); i++ {
		q := quests[i]
		if q.Status == StatusOpen || q.Status == StatusClaimed || q.Status == StatusSubmitted || q.Status == StatusDisputed {
			sum += q.BountyUgnot
		}
	}
	return sum
}

// Render serves the gnoweb Markdown interface for "", "quest/<id>", and "guild".
func Render(path string) string {
	path = strings.TrimPrefix(strings.TrimSpace(path), "/")
	if path == "" {
		return renderHome()
	}
	if path == "guild" {
		return renderGuild()
	}
	if strings.HasPrefix(path, "quest/") {
		idStr := strings.TrimPrefix(path, "quest/")
		id, err := strconv.ParseUint(idStr, 10, 64)
		if err != nil || id == 0 || id > uint64(len(quests)) {
			return "# Quest Not Found\n\nNo quest exists for path `" + path + "`.\n"
		}
		return renderQuest(quests[id-1])
	}
	return "# Gnome Tavern\n\nUnknown route `" + path + "`. Try `/` or `/guild`.\n"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Gnome Tavern Quests & Verifiable Escrow\n\n")
	b.WriteString("Deterministic on-chain quest ledger on Gno.land (`gno.land/r/nym-tavern247/tavern`).\n\n")
	b.WriteString("- **Quests Posted:** " + strconv.FormatUint(nextQuestID, 10) + "\n")
	b.WriteString("- **Active Escrow Locked:** " + strconv.FormatInt(totalLocked, 10) + " ugnot\n")
	b.WriteString("- **Cumulative Settled:** " + strconv.FormatInt(totalPaid, 10) + " ugnot\n")
	b.WriteString("- **Conservation Check:** `totalLocked == sum(active)` -> `" + strconv.FormatBool(totalLocked == ComputeActiveEscrowSum()) + "`\n\n")
	b.WriteString("[View Guild Reputation Board](/r/nym-tavern247/tavern:guild)\n\n")

	if len(quests) == 0 {
		b.WriteString("_No quests posted yet._\n")
		return b.String()
	}

	b.WriteString("## Active & Historical Quests\n\n")
	b.WriteString("| ID | Title | Bounty (ugnot) | Status | Deadline Height |\n")
	b.WriteString("| :--- | :--- | ---: | :--- | ---: |\n")
	for i := len(quests) - 1; i >= 0; i-- {
		q := quests[i]
		idStr := strconv.FormatUint(q.ID, 10)
		b.WriteString("| [#" + idStr + "](/r/nym-tavern247/tavern:quest/" + idStr + ") | " + sanitizeMarkdownCell(q.Title) + " | " + strconv.FormatInt(q.BountyUgnot, 10) + " | " + q.Status + " | " + strconv.FormatInt(q.DeadlineHeight, 10) + " |\n")
	}
	return b.String()
}

func renderQuest(q *Quest) string {
	var b strings.Builder
	idStr := strconv.FormatUint(q.ID, 10)
	b.WriteString("# Quest #" + idStr + ": " + q.Title + "\n\n")
	b.WriteString("- **Status:** " + q.Status + "\n")
	b.WriteString("- **Bounty:** " + strconv.FormatInt(q.BountyUgnot, 10) + " ugnot\n")
	b.WriteString("- **Sponsor:** `" + string(q.Sponsor) + "`\n")
	b.WriteString("- **Arbitrator:** `" + string(q.Arbitrator) + "`\n")
	if q.Worker != "" {
		b.WriteString("- **Worker:** `" + string(q.Worker) + "`\n")
	}
	b.WriteString("- **Spec SHA-256:** `" + q.SpecHash + "`\n")
	b.WriteString("- **Acceptance Criteria:** " + q.AcceptanceCriteria + "\n")
	b.WriteString("- **Deadline Height:** " + strconv.FormatInt(q.DeadlineHeight, 10) + "\n")
	if q.ProofSHA256 != "" {
		b.WriteString("- **Submitted Proof SHA-256:** `" + q.ProofSHA256 + "`\n")
		b.WriteString("- **Proof URI:** " + q.ProofURI + "\n")
	}
	if q.DisputeReason != "" {
		b.WriteString("- **Dispute Reason:** " + q.DisputeReason + "\n")
	}
	b.WriteString("\n[Back to Tavern Ledger](/r/nym-tavern247/tavern)\n")
	return b.String()
}

func renderGuild() string {
	var b strings.Builder
	b.WriteString("# Gnome Tavern Guild Reputation Board\n\n")
	if len(guildBoard) == 0 {
		b.WriteString("_No settled quests yet._\n\n[Back to Tavern Ledger](/r/nym-tavern247/tavern)\n")
		return b.String()
	}
	b.WriteString("| Builder | Completed | Disputes Won | Earned (ugnot) |\n")
	b.WriteString("| :--- | ---: | ---: | ---: |\n")
	for i := 0; i < len(guildBoard); i++ {
		g := guildBoard[i]
		b.WriteString("| `" + string(g.Address) + "` | " + strconv.FormatUint(g.Completed, 10) + " | " + strconv.FormatUint(g.DisputesWon, 10) + " | " + strconv.FormatInt(g.EarnedUgnot, 10) + " |\n")
	}
	b.WriteString("\n[Back to Tavern Ledger](/r/nym-tavern247/tavern)\n")
	return b.String()
}
