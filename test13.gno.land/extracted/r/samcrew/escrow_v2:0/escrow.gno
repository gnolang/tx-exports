package escrow_v2

// Milestone-based Escrow — On-chain freelance service contracts for Memba.
//
// Flow: CreateContract → FundMilestone → CompleteMilestone → ReleaseFunds
// Disputes: RaiseDispute → admin resolves (or auto-resolves after timeout)
// Timeouts: ClaimRefund (auto-refund if milestone not completed after N blocks)
//           ClaimDisputeTimeout (auto-release to freelancer if admin doesn't act)
//
// Security:
//   - STATE-BEFORE-SEND: All state updates happen before SendCoins calls
//   - FeeRecipient validated in init()
//   - Self-hire prevention: freelancer != client
//   - Input validation: title/description length, milestone amounts > 0
//   - Auto-refund: prevents permanent fund locking
//   - Dispute timeout: prevents permanent dispute locking
//
// Render() contract:
//   Home — Render(""):
//     # Escrow Contracts
//     | ID | Title | Client | Freelancer | Status | Total |
//
//   Detail — Render("contract/ID"):
//     # Title
//     **Client:** g1...
//     **Freelancer:** g1...
//     **Status:** active
//     ## Milestones
//     - **Milestone Title** — 1000000 ugnot [funded]

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

// ── Constants ────────────────────────────────────────────────

const (
	AdminAddress    = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0" // samcrew-core-test1 multisig
	FeeRecipient    = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0" // Samourai Coop multisig
	PlatformFeePct  = 2  // 2%
	CancelFeePct    = 5  // 5% cancellation fee
	AutoRefundBlks  = int64(864000)  // ~30 days at 3s/block
	AutoResolveBlks = int64(806400)  // ~28 days at 3s/block
	MaxTitleLen        = 200
	MaxDescLen         = 5000
	MaxMilestones      = 20
	MaxContracts       = 500
	MinMilestoneAmount = int64(1000) // 0.001 GNOT — prevents fee evasion via truncation
)

// ── Types ────────────────────────────────────────────────────

type ContractStatus string

const (
	StatusActive    ContractStatus = "active"
	StatusCompleted ContractStatus = "completed"
	StatusDisputed  ContractStatus = "disputed"
	StatusCancelled ContractStatus = "cancelled"
)

type MilestoneStatus string

const (
	MsPending   MilestoneStatus = "pending"
	MsFunded    MilestoneStatus = "funded"
	MsCompleted MilestoneStatus = "completed"
	MsReleased  MilestoneStatus = "released"
	MsDisputed  MilestoneStatus = "disputed"
	MsRefunded  MilestoneStatus = "refunded"
)

type Contract struct {
	ID          string
	Client      address
	Freelancer  address
	Title       string
	Description string
	Status      ContractStatus
	CreatedAt   int64 // block height
	Milestones  []Milestone
}

type Milestone struct {
	ID               int
	Title            string
	Amount           int64 // ugnot
	Status           MilestoneStatus
	FundedAt         int64           // block height (0 if not funded)
	CompletedAt      int64           // block height (0 if not completed)
	DisputedAt       int64           // block height (0 if not disputed)
	PreDisputeStatus MilestoneStatus // status before dispute (MsFunded or MsCompleted)
}

// ── State ────────────────────────────────────────────────────

var (
	contracts *avl.Tree // id -> *Contract
	nextID    int
	paused    bool
)

func init() {
	contracts = avl.NewTree()

	// Validate FeeRecipient at init — prevents fund-trapping panics later
	if len(FeeRecipient) == 0 {
		panic("FeeRecipient cannot be empty")
	}
}

// ── Emergency Pause ────────────────────────────────────────

func assertNotPaused() {
	if paused {
		panic("realm is paused — emergency maintenance")
	}
}

// Pause halts all write operations. Admin only.
func Pause(cur realm) {
	caller := unsafe.PreviousRealm().Address()
	if caller != address(AdminAddress) {
		panic("only admin can pause")
	}
	paused = true
}

// Unpause resumes normal operations. Admin only.
func Unpause(cur realm) {
	caller := unsafe.PreviousRealm().Address()
	if caller != address(AdminAddress) {
		panic("only admin can unpause")
	}
	paused = false
}

// IsPaused returns the current pause state.
func IsPaused() bool {
	return paused
}

// ── Contract Lifecycle ──────────────────────────────────────

// CreateContract creates a new escrow contract with milestones.
// Milestones format: "title1:amount1,title2:amount2"
func CreateContract(cur realm, freelancer address, title, description, milestones string) string {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	// Validations
	if freelancer == caller {
		panic("cannot hire yourself")
	}
	if len(title) == 0 || len(title) > MaxTitleLen {
		panic(ufmt.Sprintf("title must be 1-%d characters", MaxTitleLen))
	}
	if len(description) > MaxDescLen {
		panic(ufmt.Sprintf("description must be under %d characters", MaxDescLen))
	}
	if contracts.Size() >= MaxContracts {
		panic("contract limit reached")
	}

	ms := parseMilestones(milestones)
	if len(ms) == 0 {
		panic("at least one milestone required")
	}
	if len(ms) > MaxMilestones {
		panic(ufmt.Sprintf("maximum %d milestones allowed", MaxMilestones))
	}

	id := strconv.Itoa(nextID)
	nextID++

	c := &Contract{
		ID:          id,
		Client:      caller,
		Freelancer:  freelancer,
		Title:       sanitizeMilestoneTitle(title),
		Description: sanitizeMilestoneTitle(description),
		Status:      StatusActive,
		CreatedAt:   runtime.ChainHeight(),
		Milestones:  ms,
	}
	contracts.Set(id, c)

	chain.Emit("ContractCreated",
		"id", id,
		"client", caller.String(),
		"freelancer", freelancer.String(),
		"milestones", strconv.Itoa(len(ms)),
	)
	return id
}

// FundMilestone deposits funds for a specific milestone. Client only.
func FundMilestone(cur realm, contractId string, milestoneIdx int) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	c := getContract(contractId)

	if c.Client != caller {
		panic("only client can fund")
	}
	if c.Status != StatusActive {
		panic("contract not active")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(c.Milestones) {
		panic("invalid milestone index")
	}

	ms := &c.Milestones[milestoneIdx]
	if ms.Status != MsPending {
		panic("milestone already funded or processed")
	}

	// Verify coins sent (accumulate to handle multi-entry defensively)
	sent := unsafe.OriginSend()
	sentAmount := int64(0)
	for _, coin := range sent {
		if coin.Denom == "ugnot" {
			sentAmount += coin.Amount
		}
	}
	if sentAmount != ms.Amount {
		panic(ufmt.Sprintf("must send exactly %d ugnot (sent %d)", ms.Amount, sentAmount))
	}

	ms.Status = MsFunded
	ms.FundedAt = runtime.ChainHeight()
	contracts.Set(contractId, c)

	chain.Emit("MilestoneFunded",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"amount", strconv.FormatInt(ms.Amount, 10),
	)
}

// CompleteMilestone marks a milestone as completed. Freelancer only.
func CompleteMilestone(cur realm, contractId string, milestoneIdx int) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	c := getContract(contractId)

	if c.Freelancer != caller {
		panic("only freelancer can mark complete")
	}
	// Only allow completion when contract is Active. Disputed contracts are frozen
	// until ResolveDispute/ClaimDisputeTimeout returns the contract to Active.
	if c.Status != StatusActive {
		panic("contract is " + string(c.Status) + " — cannot complete milestones during dispute")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(c.Milestones) {
		panic("invalid milestone index")
	}

	ms := &c.Milestones[milestoneIdx]
	if ms.Status != MsFunded {
		panic("milestone not funded")
	}

	ms.Status = MsCompleted
	ms.CompletedAt = runtime.ChainHeight()
	contracts.Set(contractId, c)

	chain.Emit("MilestoneCompleted",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"freelancer", caller.String(),
	)
}

// ReleaseFunds releases funds to freelancer after client approves. Client or Admin.
func ReleaseFunds(cur realm, contractId string, milestoneIdx int) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	c := getContract(contractId)

	if c.Client != caller && caller != address(AdminAddress) {
		panic("only client or admin can release")
	}
	// Only allow release when contract is Active. Disputed contracts are frozen
	// until ResolveDispute/ClaimDisputeTimeout returns the contract to Active.
	if c.Status != StatusActive {
		panic("contract is " + string(c.Status) + " — cannot release funds during dispute")
	}
	if milestoneIdx < 0 || milestoneIdx >= len(c.Milestones) {
		panic("invalid milestone index")
	}

	ms := &c.Milestones[milestoneIdx]
	if ms.Status != MsCompleted {
		panic("milestone not completed")
	}

	// Calculate fees
	platformAmount := (ms.Amount * int64(PlatformFeePct)) / 100
	freelancerAmount := ms.Amount - platformAmount

	// STATE-BEFORE-SEND: update all state before any coin transfers
	ms.Status = MsReleased
	if allMilestonesReleased(c) {
		c.Status = StatusCompleted
	}
	contracts.Set(contractId, c)

	// Transfer funds
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := unsafe.CurrentRealm().Address()

	bnk.SendCoins(realmAddr, c.Freelancer, chain.Coins{chain.NewCoin("ugnot", freelancerAmount)})
	if platformAmount > 0 {
		bnk.SendCoins(realmAddr, address(FeeRecipient), chain.Coins{chain.NewCoin("ugnot", platformAmount)})
	}

	chain.Emit("FundsReleased",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"freelancer", c.Freelancer.String(),
		"amount", strconv.FormatInt(freelancerAmount, 10),
		"fee", strconv.FormatInt(platformAmount, 10),
	)
}

// ── Disputes ────────────────────────────────────────────────

// RaiseDispute escalates a milestone to admin arbitration. Client or Freelancer.
func RaiseDispute(cur realm, contractId string, milestoneIdx int) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	c := getContract(contractId)

	if c.Client != caller && c.Freelancer != caller {
		panic("only client or freelancer can dispute")
	}
	if c.Status == StatusCancelled || c.Status == StatusCompleted {
		panic("contract is " + string(c.Status))
	}
	if milestoneIdx < 0 || milestoneIdx >= len(c.Milestones) {
		panic("invalid milestone index")
	}

	ms := &c.Milestones[milestoneIdx]
	if ms.Status != MsFunded && ms.Status != MsCompleted {
		panic("can only dispute funded or completed milestones")
	}

	// Capture pre-dispute status so ClaimDisputeTimeout can resolve fairly:
	// if work was delivered (MsCompleted), pay freelancer; if not (MsFunded), refund client.
	ms.PreDisputeStatus = ms.Status
	ms.Status = MsDisputed
	ms.DisputedAt = runtime.ChainHeight()
	c.Status = StatusDisputed
	contracts.Set(contractId, c)

	chain.Emit("DisputeRaised",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"raisedBy", caller.String(),
	)
}

// ResolveDispute resolves a dispute. Admin only.
// refundClient=true refunds to client, false pays freelancer.
func ResolveDispute(cur realm, contractId string, milestoneIdx int, refundClient bool) {
	caller := unsafe.PreviousRealm().Address()
	if caller != address(AdminAddress) {
		panic("only admin can resolve disputes")
	}

	c := getContract(contractId)
	if milestoneIdx < 0 || milestoneIdx >= len(c.Milestones) {
		panic("invalid milestone index")
	}

	ms := &c.Milestones[milestoneIdx]
	if ms.Status != MsDisputed {
		panic("milestone not in dispute")
	}

	// STATE-BEFORE-SEND: update state before transfers
	if refundClient {
		ms.Status = MsRefunded
	} else {
		ms.Status = MsReleased
	}
	// Reset contract status if no other milestones are disputed
	c.Status = StatusActive
	for _, m := range c.Milestones {
		if m.Status == MsDisputed {
			c.Status = StatusDisputed
			break
		}
	}
	if allMilestonesReleased(c) {
		c.Status = StatusCompleted
	}
	contracts.Set(contractId, c)

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := unsafe.CurrentRealm().Address()

	if refundClient {
		bnk.SendCoins(realmAddr, c.Client, chain.Coins{chain.NewCoin("ugnot", ms.Amount)})
	} else {
		platformAmount := (ms.Amount * int64(PlatformFeePct)) / 100
		freelancerAmount := ms.Amount - platformAmount
		bnk.SendCoins(realmAddr, c.Freelancer, chain.Coins{chain.NewCoin("ugnot", freelancerAmount)})
		if platformAmount > 0 {
			bnk.SendCoins(realmAddr, address(FeeRecipient), chain.Coins{chain.NewCoin("ugnot", platformAmount)})
		}
	}

	resolution := "released-to-freelancer"
	if refundClient {
		resolution = "refunded-to-client"
	}
	chain.Emit("DisputeResolved",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"resolution", resolution,
	)
}

// ── Cancellation ────────────────────────────────────────────

// CancelContract cancels an active contract. Client only.
// Funded milestones are refunded minus cancellation fee.
func CancelContract(cur realm, contractId string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	c := getContract(contractId)

	if c.Client != caller {
		panic("only client can cancel")
	}
	if c.Status != StatusActive {
		panic("contract not active")
	}

	// STATE-BEFORE-SEND: update all state before transfers.
	// Track which milestones are NEWLY transitioned so we only pay those,
	// preventing double-refund of milestones already resolved via ResolveDispute.
	c.Status = StatusCancelled
	var newlyRefunded []int
	var newlyReleased []int
	for i := range c.Milestones {
		if c.Milestones[i].Status == MsFunded {
			c.Milestones[i].Status = MsRefunded
			newlyRefunded = append(newlyRefunded, i)
		} else if c.Milestones[i].Status == MsCompleted {
			c.Milestones[i].Status = MsReleased
			newlyReleased = append(newlyReleased, i)
		}
		// Already-terminal milestones (MsRefunded from ResolveDispute, MsReleased from
		// ReleaseFunds) are NOT added to the payment lists — their funds were already
		// distributed in the original operation.
	}
	contracts.Set(contractId, c)

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := unsafe.CurrentRealm().Address()

	for _, i := range newlyRefunded {
		ms := c.Milestones[i]
		// Refund funded milestones minus cancellation fee
		fee := (ms.Amount * int64(CancelFeePct)) / 100
		refund := ms.Amount - fee
		if refund > 0 {
			bnk.SendCoins(realmAddr, c.Client, chain.Coins{chain.NewCoin("ugnot", refund)})
		}
		// Cancellation fee goes to freelancer as compensation for lost opportunity
		if fee > 0 {
			bnk.SendCoins(realmAddr, c.Freelancer, chain.Coins{chain.NewCoin("ugnot", fee)})
		}
	}
	for _, i := range newlyReleased {
		ms := c.Milestones[i]
		// Pay freelancer for completed work (full amount minus platform fee)
		platformAmount := (ms.Amount * int64(PlatformFeePct)) / 100
		freelancerAmount := ms.Amount - platformAmount
		bnk.SendCoins(realmAddr, c.Freelancer, chain.Coins{chain.NewCoin("ugnot", freelancerAmount)})
		if platformAmount > 0 {
			bnk.SendCoins(realmAddr, address(FeeRecipient), chain.Coins{chain.NewCoin("ugnot", platformAmount)})
		}
	}
}

// ── Timeouts (permissionless) ───────────────────────────────

// ClaimRefund refunds a funded milestone that has timed out.
// Anyone can call — permissionless, prevents fund locking.
func ClaimRefund(cur realm, contractId string, milestoneIdx int) {
	c := getContract(contractId)

	if milestoneIdx < 0 || milestoneIdx >= len(c.Milestones) {
		panic("invalid milestone index")
	}

	ms := &c.Milestones[milestoneIdx]
	if ms.Status != MsFunded {
		panic("milestone not funded")
	}
	if ms.FundedAt == 0 {
		panic("milestone has no funding record")
	}

	elapsed := runtime.ChainHeight() - ms.FundedAt
	if elapsed < AutoRefundBlks {
		panic(ufmt.Sprintf("too early: %d blocks remaining", AutoRefundBlks-elapsed))
	}

	// STATE-BEFORE-SEND
	ms.Status = MsRefunded
	// Update contract status if all milestones are now terminal
	if allMilestonesTerminal(c) {
		c.Status = StatusCancelled
	}
	contracts.Set(contractId, c)

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(
		unsafe.CurrentRealm().Address(),
		c.Client,
		chain.Coins{chain.NewCoin("ugnot", ms.Amount)},
	)
}

// ClaimDisputeTimeout auto-resolves a dispute that admin hasn't acted on after
// AutoResolveBlks (~28 days). Resolution follows the pre-dispute status:
//   - If the milestone was MsCompleted (freelancer delivered work) before dispute,
//     funds go to freelancer (minus platform fee). This prevents griefing where
//     a client disputes after delivery and simply waits out the clock.
//   - If the milestone was MsFunded (work not yet delivered) before dispute,
//     funds are refunded to client.
// Anyone can call (permissionless safety valve).
func ClaimDisputeTimeout(cur realm, contractId string, milestoneIdx int) {
	c := getContract(contractId)

	if milestoneIdx < 0 || milestoneIdx >= len(c.Milestones) {
		panic("invalid milestone index")
	}

	ms := &c.Milestones[milestoneIdx]
	if ms.Status != MsDisputed {
		panic("milestone not in dispute")
	}
	if ms.DisputedAt == 0 {
		panic("milestone has no dispute record")
	}

	elapsed := runtime.ChainHeight() - ms.DisputedAt
	if elapsed < AutoResolveBlks {
		panic(ufmt.Sprintf("too early: %d blocks remaining", AutoResolveBlks-elapsed))
	}

	// Resolve based on pre-dispute status — fair to both parties.
	payFreelancer := ms.PreDisputeStatus == MsCompleted

	// STATE-BEFORE-SEND
	if payFreelancer {
		ms.Status = MsReleased
	} else {
		ms.Status = MsRefunded
	}
	// Reset contract status
	c.Status = StatusActive
	for _, m := range c.Milestones {
		if m.Status == MsDisputed {
			c.Status = StatusDisputed
			break
		}
	}
	if allMilestonesReleased(c) {
		c.Status = StatusCompleted
	} else if allMilestonesTerminal(c) {
		c.Status = StatusCancelled
	}
	contracts.Set(contractId, c)

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := unsafe.CurrentRealm().Address()

	if payFreelancer {
		// Work was delivered — pay freelancer minus platform fee
		platformAmount := (ms.Amount * int64(PlatformFeePct)) / 100
		freelancerAmount := ms.Amount - platformAmount
		bnk.SendCoins(realmAddr, c.Freelancer, chain.Coins{chain.NewCoin("ugnot", freelancerAmount)})
		if platformAmount > 0 {
			bnk.SendCoins(realmAddr, address(FeeRecipient), chain.Coins{chain.NewCoin("ugnot", platformAmount)})
		}
		chain.Emit("DisputeTimedOut",
			"contractId", contractId,
			"milestone", strconv.Itoa(milestoneIdx),
			"resolution", "paid-freelancer-work-delivered",
		)
	} else {
		// Work never delivered — refund client in full
		bnk.SendCoins(realmAddr, c.Client, chain.Coins{chain.NewCoin("ugnot", ms.Amount)})
		chain.Emit("DisputeTimedOut",
			"contractId", contractId,
			"milestone", strconv.Itoa(milestoneIdx),
			"resolution", "refunded-client-no-delivery",
		)
	}
}

// ── Render ───────────────────────────────────────────────────

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "contract/") {
		id := strings.TrimPrefix(path, "contract/")
		return renderContract(id)
	}
	if path == "stats" {
		return renderStats()
	}
	return "# 404\nNot found: " + path
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# Escrow Contracts\n\n")
	sb.WriteString("Milestone-based escrow for freelance services on Gno.\n\n")

	if contracts.Size() == 0 {
		sb.WriteString("*No contracts yet.*\n")
		return sb.String()
	}

	sb.WriteString("| ID | Title | Client | Freelancer | Status | Total |\n")
	sb.WriteString("| --- | --- | --- | --- | --- | --- |\n")

	contracts.Iterate("", "", func(key string, value interface{}) bool {
		c := value.(*Contract)
		total := int64(0)
		for _, ms := range c.Milestones {
			total += ms.Amount
		}
		sb.WriteString(ufmt.Sprintf("| %s | [%s](:contract/%s) | %s | %s | %s | %d ugnot |\n",
			c.ID, c.Title, c.ID, truncAddr(c.Client), truncAddr(c.Freelancer),
			string(c.Status), total))
		return false
	})

	return sb.String()
}

func renderContract(id string) string {
	val, exists := contracts.Get(id)
	if !exists {
		return "# 404\nContract not found: " + id
	}
	c := val.(*Contract)

	var sb strings.Builder
	sb.WriteString("# " + c.Title + "\n\n")
	if len(c.Description) > 0 {
		sb.WriteString(c.Description + "\n\n")
	}
	sb.WriteString("**ID:** " + c.ID + "\n")
	sb.WriteString("**Client:** " + c.Client.String() + "\n")
	sb.WriteString("**Freelancer:** " + c.Freelancer.String() + "\n")
	sb.WriteString("**Status:** " + string(c.Status) + "\n")
	sb.WriteString("**Created:** block " + strconv.FormatInt(c.CreatedAt, 10) + "\n\n")

	total := int64(0)
	for _, ms := range c.Milestones {
		total += ms.Amount
	}
	sb.WriteString("**Total Value:** " + strconv.FormatInt(total, 10) + " ugnot\n\n")

	sb.WriteString("## Milestones\n\n")
	for _, ms := range c.Milestones {
		sb.WriteString(ufmt.Sprintf("- **%s** — %d ugnot [%s]",
			ms.Title, ms.Amount, string(ms.Status)))
		if ms.FundedAt > 0 {
			sb.WriteString(ufmt.Sprintf(" (funded block %d)", ms.FundedAt))
		}
		if ms.CompletedAt > 0 {
			sb.WriteString(ufmt.Sprintf(" (completed block %d)", ms.CompletedAt))
		}
		if ms.DisputedAt > 0 {
			sb.WriteString(ufmt.Sprintf(" (disputed block %d)", ms.DisputedAt))
		}
		sb.WriteString("\n")
	}

	return sb.String()
}

func renderStats() string {
	var sb strings.Builder
	sb.WriteString("# Escrow Stats\n\n")

	totalContracts := contracts.Size()
	active, completed, disputed, cancelled := 0, 0, 0, 0
	totalValue := int64(0)

	contracts.Iterate("", "", func(key string, value interface{}) bool {
		c := value.(*Contract)
		switch c.Status {
		case StatusActive:
			active++
		case StatusCompleted:
			completed++
		case StatusDisputed:
			disputed++
		case StatusCancelled:
			cancelled++
		}
		for _, ms := range c.Milestones {
			totalValue += ms.Amount
		}
		return false
	})

	sb.WriteString(ufmt.Sprintf("**Total Contracts:** %d\n", totalContracts))
	sb.WriteString(ufmt.Sprintf("**Active:** %d | **Completed:** %d | **Disputed:** %d | **Cancelled:** %d\n", active, completed, disputed, cancelled))
	sb.WriteString(ufmt.Sprintf("**Total Value:** %d ugnot\n", totalValue))

	return sb.String()
}

// ── Helpers ──────────────────────────────────────────────────

func getContract(id string) *Contract {
	val, exists := contracts.Get(id)
	if !exists {
		panic("contract not found: " + id)
	}
	return val.(*Contract)
}

func allMilestonesReleased(c *Contract) bool {
	for _, m := range c.Milestones {
		if m.Status != MsReleased {
			return false
		}
	}
	return true
}

// allMilestonesTerminal returns true if every milestone is in a final state
// (released, refunded, or pending — pending with no funds is terminal).
func allMilestonesTerminal(c *Contract) bool {
	for _, m := range c.Milestones {
		if m.Status == MsFunded || m.Status == MsCompleted || m.Status == MsDisputed {
			return false
		}
	}
	return true
}

// parseMilestones parses "title1:amount1,title2:amount2" into Milestone slice.
// Invalid entries cause a panic (not silently skipped).
func parseMilestones(input string) []Milestone {
	var result []Milestone
	parts := strings.Split(input, ",")
	for i, p := range parts {
		p = strings.TrimSpace(p)
		if len(p) == 0 {
			continue
		}
		kv := strings.SplitN(p, ":", 2)
		if len(kv) != 2 {
			panic(ufmt.Sprintf("invalid milestone format at position %d: expected 'title:amount'", i))
		}
		title := strings.TrimSpace(kv[0])
		if len(title) == 0 {
			panic(ufmt.Sprintf("empty milestone title at position %d", i))
		}
		if len(title) > MaxTitleLen {
			panic(ufmt.Sprintf("milestone title too long at position %d: %d/%d chars", i, len(title), MaxTitleLen))
		}
		title = sanitizeMilestoneTitle(title)
		amount, err := strconv.ParseInt(strings.TrimSpace(kv[1]), 10, 64)
		if err != nil || amount <= 0 {
			panic(ufmt.Sprintf("invalid milestone amount at position %d: must be positive integer", i))
		}
		// Minimum milestone amount prevents fee evasion via integer truncation.
		// At 2% fee, amounts < 50 ugnot would pay 0 fee.
		if amount < MinMilestoneAmount {
			panic(ufmt.Sprintf("milestone amount too small at position %d: minimum %d ugnot", i, MinMilestoneAmount))
		}
		result = append(result, Milestone{
			ID:     i,
			Title:  title,
			Amount: amount,
			Status: MsPending,
		})
	}
	return result
}

func truncAddr(addr address) string {
	s := addr.String()
	if len(s) > 13 {
		return s[:10] + "..."
	}
	return s
}

// sanitizeMilestoneTitle strips markdown special characters to prevent injection
// in gnoweb Render output.
func sanitizeMilestoneTitle(s string) string {
	var out strings.Builder
	for _, c := range s {
		switch c {
		case '[', ']', '(', ')', '#', '*', '`', '!', '<', '>', '|', '\\', '_', '~', '\n', '\r', '\t':
			continue // strip markdown-sensitive characters and control whitespace
		default:
			out.WriteRune(c)
		}
	}
	return out.String()
}
