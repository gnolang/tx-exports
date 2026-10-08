package escrow_v4

// Milestone-based escrow: on-chain freelance service contracts for Memba.
// Successor of escrow_v3 with the same user API; see DESIGN.md for what
// changed and why.
//
// Flow: CreateContract → FundMilestone → CompleteMilestone → ReleaseFunds
// Disputes: RaiseDispute → admin ResolveDispute (or ClaimDisputeTimeout after
//           AutoResolveBlks)
// Timeouts: ClaimRefund (a funded milestone nobody completed, after
//           AutoRefundBlks); ExpireUnfunded (a contract never funded, after
//           UnfundedExpiryBlks)
// Cleanup:  ArchiveContract (client deletes a settled contract; the chain
//           refunds the freed storage deposit to the signer)
//
// Invariants:
//   - State is updated before any coins are sent.
//   - realm balance >= TotalLiabilities() (NF-2).
//   - A contract is open until it is completed or cancelled; an open contract
//     holds one of its client's MaxActivePerClient slots.
//   - completed and cancelled are absorbing and hold no escrowed funds.
//
// Caller authentication: every crossing entrypoint checks cur.IsCurrent() and
// reads the caller from cur.Previous(). Every use of the unsafe runtime
// package is in origin.gno. Read-only views are in views.gno.

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/samcrew/avl"
	cfg "gno.land/r/samcrew/memba_market_config"
)

// ── Constants ────────────────────────────────────────────────

// laneService is this engine's lane key into the DAO fee spine
// (memba_market_config), seeded there at 200 bps.
const laneService = "service"

const (
	// PlatformFeePct is only the fail-safe fallback rate (see resolveFee); the
	// live rate is cfg.GetFeeBPS(laneService), read at each payout.
	PlatformFeePct = 2
	// CancelFeePct is paid to the freelancer from each funded milestone when
	// the client cancels. Escrow-internal, not a protocol fee.
	CancelFeePct = 5
	// Timeouts, in blocks, as in v3 (sized at 3 s per block; at gnoland-1's
	// ~3.3 s they are ~33 and ~31 days). Blocks inside a pause's blocking
	// window do not count (see the pause section).
	AutoRefundBlks  = int64(864000)
	AutoResolveBlks = int64(806400)
	// UnfundedExpiryBlks: a contract none of whose milestones was ever funded
	// can be cancelled by anyone after this many blocks, freeing its slot.
	UnfundedExpiryBlks = AutoRefundBlks

	MaxTitleLen        = 200  // bytes, after sanitising (also bounds the input)
	MaxDescLen         = 5000 // bytes, after sanitising (also bounds the input)
	MaxMilestones      = 20
	MinMilestoneAmount = int64(1000) // 0.001 GNOT: below ~50 ugnot a 2% fee truncates to 0
	// maxMilestonesArgLen bounds the raw milestones argument before parsing:
	// 20 entries of a 200-byte title, a 19-digit amount and separators, with
	// room for surrounding spaces.
	maxMilestonesArgLen = MaxMilestones * (MaxTitleLen + 64)

	// MaxActivePerClient bounds the open contracts one client address may
	// hold. It counts only contracts the address created, never those naming
	// it as freelancer, so nobody can use up someone else's slots, and it
	// bounds what one key can lock (five of the largest contracts are about
	// 15 GNOT of storage deposit). There is no global cap: nothing iterates
	// over every contract, so a global number would bound no gas and would
	// only give a funded attacker a switch to turn escrow off for everyone.
	MaxActivePerClient = 5
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

	createdPauseMark int64 // pausedBlocksAt(CreatedAt), for UnfundedExpiryBlks
}

type Milestone struct {
	ID               int // equals the milestone's index
	Title            string
	Amount           int64 // ugnot
	Status           MilestoneStatus
	FundedAt         int64           // block height (0 if not funded)
	CompletedAt      int64           // block height (0 if not completed)
	DisputedAt       int64           // block height (0 if not disputed)
	PreDisputeStatus MilestoneStatus // status before dispute (MsFunded or MsCompleted)

	fundedPauseMark   int64 // pausedBlocksAt(FundedAt), for AutoRefundBlks
	disputedPauseMark int64 // pausedBlocksAt(DisputedAt), for AutoResolveBlks
}

// ── State ────────────────────────────────────────────────────

var (
	contracts     *avl.Tree // id -> *Contract; live (not archived) contracts only
	clientSlots   *avl.Tree // client address -> int open contracts (removed on archive once 0); "c/<client>/<id>" -> nil client index
	nextID        int       // monotonic, never reused
	activeCount   int       // open contracts
	archivedCount int
	totalLiable   int64 // NF-2: ugnot owed to funded, completed and disputed milestones
)

func init() {
	contracts = avl.NewTree()
	clientSlots = avl.NewTree()
}

// resolveFee reads the "service" lane fee (bps) and treasury from the DAO fee
// spine at payout time. The config getters are pure and non-failing; on an
// out-of-range rate or an empty or malformed treasury this falls back to the
// frozen rate and the realm's fee recipient rather than reverting a payout, so
// a config mistake never strands escrowed funds.
func resolveFee() (int64, address) {
	bps := int64(cfg.GetFeeBPS(laneService))
	if bps < 0 || bps > cfg.MaxFeeBPS {
		bps = int64(PlatformFeePct) * 100
	}
	treasury := cfg.GetTreasury()
	if treasury == "" || !treasury.IsValid() {
		treasury = feeRecipient
	}
	return bps, treasury
}

// callerOf returns the immediate caller of a crossing entrypoint.
func callerOf(cur realm) address {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	return cur.Previous().Address()
}

// ── Contract lifecycle ───────────────────────────────────────

// CreateContract creates a new escrow contract with milestones, as the
// caller's client. Milestones format: "title1:amount1,title2:amount2".
// The caller must be a user (a direct call or the user's own run script), so a
// realm cannot mint client identities with cur.Sub to hold slots.
func CreateContract(cur realm, freelancer address, title, description, milestones string) string {
	assertAcceptsNewMoney()
	caller := callerOf(cur)
	if !cur.Previous().IsUser() {
		panic("CreateContract must be called by a user, not a realm")
	}
	if !freelancer.IsValid() {
		panic("invalid freelancer address")
	}
	if freelancer == caller {
		panic("cannot hire yourself")
	}
	if len(title) == 0 {
		panic(ufmt.Sprintf("title must be 1-%d characters", MaxTitleLen))
	}
	cleanTitle := cleanText(title, "title", MaxTitleLen)
	if strings.TrimSpace(cleanTitle) == "" {
		panic("title must contain visible characters")
	}
	cleanDesc := cleanText(description, "description", MaxDescLen)

	ms := parseMilestones(milestones)
	if len(ms) == 0 {
		panic("at least one milestone required")
	}
	if len(ms) > MaxMilestones {
		panic(ufmt.Sprintf("maximum %d milestones allowed", MaxMilestones))
	}

	takeSlot(caller)
	n := nextID
	id := strconv.Itoa(n)
	nextID++
	clientSlots.Set(indexKey(caller, n), nil) // client index (views.gno)
	now := runtime.ChainHeight()
	contracts.Set(id, &Contract{
		ID:               id,
		Client:           caller,
		Freelancer:       freelancer,
		Title:            cleanTitle,
		Description:      cleanDesc,
		Status:           StatusActive,
		CreatedAt:        now,
		Milestones:       ms,
		createdPauseMark: pausedBlocksAt(now),
	})

	chain.Emit("ContractCreated",
		"id", id,
		"client", caller.String(),
		"freelancer", freelancer.String(),
		"milestones", strconv.Itoa(len(ms)),
	)
	return id
}

// FundMilestone deposits exactly the milestone amount. Client only, and only
// as a direct user call: the tx-level send lands on the message's target
// realm, so from an intermediary realm the coins would never reach escrow
// while the milestone was marked funded.
func FundMilestone(cur realm, contractId string, milestoneIdx int) {
	assertAcceptsNewMoney()
	caller := callerOf(cur)
	if !cur.Previous().IsUserCall() {
		panic("FundMilestone must be a direct user call")
	}
	c := getContract(contractId)
	if c.Client != caller {
		panic("only client can fund")
	}
	if c.Status != StatusActive {
		panic("contract not active")
	}
	ms := milestoneAt(c, milestoneIdx)
	if ms.Status != MsPending {
		panic("milestone already funded or processed")
	}
	requireExactSend(ms.Amount, cur.Previous())

	now := runtime.ChainHeight()
	ms.Status = MsFunded
	ms.FundedAt = now
	ms.fundedPauseMark = pausedBlocksAt(now)
	totalLiable += ms.Amount

	chain.Emit("MilestoneFunded",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"amount", strconv.FormatInt(ms.Amount, 10),
	)
}

// CompleteMilestone marks a funded milestone delivered. Freelancer only.
func CompleteMilestone(cur realm, contractId string, milestoneIdx int) {
	assertOpen()
	caller := callerOf(cur)
	c := getContract(contractId)
	if c.Freelancer != caller {
		panic("only freelancer can mark complete")
	}
	// A disputed contract is frozen until the dispute is resolved.
	if c.Status != StatusActive {
		panic("contract is " + string(c.Status) + " — cannot complete milestones during dispute")
	}
	ms := milestoneAt(c, milestoneIdx)
	if ms.Status != MsFunded {
		panic("milestone not funded")
	}

	ms.Status = MsCompleted
	ms.CompletedAt = runtime.ChainHeight()

	chain.Emit("MilestoneCompleted",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"freelancer", caller.String(),
	)
}

// ReleaseFunds pays a completed milestone to the freelancer, minus the fee.
// Client, or admin as the trusted arbiter (v3 behaviour).
func ReleaseFunds(cur realm, contractId string, milestoneIdx int) {
	assertOpen()
	caller := callerOf(cur)
	c := getContract(contractId)
	if c.Client != caller && caller != admin {
		panic("only client or admin can release")
	}
	if c.Status != StatusActive {
		panic("contract is " + string(c.Status) + " — cannot release funds during dispute")
	}
	ms := milestoneAt(c, milestoneIdx)
	if ms.Status != MsCompleted {
		panic("milestone not completed")
	}

	ms.Status = MsReleased
	settleIfFinished(c)
	totalLiable -= ms.Amount

	p := payFreelancer(cur, c, ms.Amount)

	chain.Emit("FundsReleased",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"freelancer", c.Freelancer.String(),
		"amount", strconv.FormatInt(p.net, 10),
		"fee", strconv.FormatInt(p.fee, 10),
		"bps", strconv.FormatInt(p.bps, 10),
		"treasury", p.treasury.String(),
		"status", string(c.Status),
	)
}

// ── Disputes ─────────────────────────────────────────────────

// RaiseDispute escalates a funded or completed milestone to the admin.
// Client or freelancer.
func RaiseDispute(cur realm, contractId string, milestoneIdx int) {
	assertOpen()
	caller := callerOf(cur)
	c := getContract(contractId)
	if c.Client != caller && c.Freelancer != caller {
		panic("only client or freelancer can dispute")
	}
	if !isOpen(c) {
		panic("contract is " + string(c.Status))
	}
	ms := milestoneAt(c, milestoneIdx)
	if ms.Status != MsFunded && ms.Status != MsCompleted {
		panic("can only dispute funded or completed milestones")
	}

	// ClaimDisputeTimeout pays the freelancer if the work had been delivered
	// (MsCompleted) and refunds the client otherwise.
	now := runtime.ChainHeight()
	ms.PreDisputeStatus = ms.Status
	ms.Status = MsDisputed
	ms.DisputedAt = now
	ms.disputedPauseMark = pausedBlocksAt(now)
	c.Status = StatusDisputed

	chain.Emit("DisputeRaised",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"raisedBy", caller.String(),
	)
}

// ResolveDispute settles a disputed milestone. Admin only.
// refundClient=true refunds the client in full; false pays the freelancer
// minus the fee. The contract then returns to active, stays disputed if
// another milestone still is, or settles: completed if every milestone is
// released, cancelled if every milestone is released or refunded.
func ResolveDispute(cur realm, contractId string, milestoneIdx int, refundClient bool) {
	assertOpen()
	if callerOf(cur) != admin {
		panic("only admin can resolve disputes")
	}
	c := getContract(contractId)
	ms := milestoneAt(c, milestoneIdx)
	if ms.Status != MsDisputed {
		panic("milestone not in dispute")
	}

	if refundClient {
		ms.Status = MsRefunded
	} else {
		ms.Status = MsReleased
	}
	c.Status = StatusActive
	if anyMilestoneDisputed(c) {
		c.Status = StatusDisputed
	}
	settleIfFinished(c)
	totalLiable -= ms.Amount

	var p payout
	resolution := "released-to-freelancer"
	if refundClient {
		resolution = "refunded-to-client"
		send(cur, c.Client, ms.Amount)
		p = payout{net: ms.Amount, recipient: c.Client}
	} else {
		p = payFreelancer(cur, c, ms.Amount)
	}
	chain.Emit("DisputeResolved",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"resolution", resolution,
		"recipient", p.recipient.String(),
		"amount", strconv.FormatInt(p.net, 10),
		"fee", strconv.FormatInt(p.fee, 10),
		"bps", strconv.FormatInt(p.bps, 10),
		"treasury", p.treasury.String(),
		"status", string(c.Status),
	)
}

// ── Cancellation and expiry ──────────────────────────────────

// CancelContract cancels an active contract. Client only. Funded milestones
// are refunded minus CancelFeePct, which goes to the freelancer; completed
// milestones are paid to the freelancer minus the service fee.
func CancelContract(cur realm, contractId string) {
	assertOpen()
	caller := callerOf(cur)
	c := getContract(contractId)
	if c.Client != caller {
		panic("only client can cancel")
	}
	if c.Status != StatusActive {
		panic("contract not active")
	}

	// Only milestones transitioned here are paid, so a milestone already
	// refunded or released is never paid twice.
	var refunded, released []int
	for i := range c.Milestones {
		switch c.Milestones[i].Status {
		case MsFunded:
			c.Milestones[i].Status = MsRefunded
			refunded = append(refunded, i)
		case MsCompleted:
			c.Milestones[i].Status = MsReleased
			released = append(released, i)
		}
	}
	settle(c, StatusCancelled)
	for _, i := range refunded {
		totalLiable -= c.Milestones[i].Amount
	}
	for _, i := range released {
		totalLiable -= c.Milestones[i].Amount
	}

	var toClient, compensation, toFreelancer, fees, bps int64
	var treasury address
	for _, i := range refunded {
		amount := c.Milestones[i].Amount
		fee := basisPointsFee(amount, int64(CancelFeePct)*100)
		send(cur, c.Client, amount-fee)
		send(cur, c.Freelancer, fee)
		toClient += amount - fee
		compensation += fee
	}
	for _, i := range released {
		p := payFreelancer(cur, c, c.Milestones[i].Amount)
		toFreelancer += p.net
		fees += p.fee
		bps, treasury = p.bps, p.treasury
	}

	chain.Emit("ContractCancelled",
		"contractId", contractId,
		"client", c.Client.String(),
		"freelancer", c.Freelancer.String(),
		"refunded", strconv.Itoa(len(refunded)),
		"released", strconv.Itoa(len(released)),
		"refundToClient", strconv.FormatInt(toClient, 10),
		"cancelCompensation", strconv.FormatInt(compensation, 10),
		"cancelFeeBps", strconv.FormatInt(int64(CancelFeePct)*100, 10),
		"releasedToFreelancer", strconv.FormatInt(toFreelancer, 10),
		"fee", strconv.FormatInt(fees, 10),
		"bps", strconv.FormatInt(bps, 10),
		"treasury", treasury.String(),
	)
}

// ExpireUnfunded cancels a contract none of whose milestones was ever funded,
// once UnfundedExpiryBlks have passed since creation (blocking-window blocks
// excluded). Anyone may call. It frees the client's slot and moves no coins;
// it does not delete, so the storage deposit stays for the client's
// ArchiveContract.
func ExpireUnfunded(cur realm, contractId string) {
	assertOpen()
	caller := callerOf(cur)
	c := getContract(contractId)
	if c.Status != StatusActive {
		panic("contract not active")
	}
	for _, m := range c.Milestones {
		if m.Status != MsPending {
			panic("contract was funded; use ClaimRefund or CancelContract")
		}
	}
	elapsed := elapsedOpen(c.CreatedAt, c.createdPauseMark)
	if elapsed < UnfundedExpiryBlks {
		panic(ufmt.Sprintf("too early: %d blocks remaining", UnfundedExpiryBlks-elapsed))
	}

	settle(c, StatusCancelled)

	chain.Emit("ContractExpired",
		"contractId", contractId,
		"client", c.Client.String(),
		"expiredBy", caller.String(),
	)
}

// ── Timeouts (permissionless) ────────────────────────────────

// ClaimRefund refunds a funded milestone nobody completed within
// AutoRefundBlks (blocking-window blocks excluded). Anyone may call; the
// client receives the funds. If no milestone then holds funds the contract is
// cancelled, pending milestones included (v3 behaviour).
func ClaimRefund(cur realm, contractId string, milestoneIdx int) {
	assertOpen()
	c := getContract(contractId)
	ms := milestoneAt(c, milestoneIdx)
	if ms.Status != MsFunded {
		panic("milestone not funded")
	}
	if ms.FundedAt == 0 {
		panic("milestone has no funding record")
	}
	elapsed := elapsedOpen(ms.FundedAt, ms.fundedPauseMark)
	if elapsed < AutoRefundBlks {
		panic(ufmt.Sprintf("too early: %d blocks remaining", AutoRefundBlks-elapsed))
	}

	ms.Status = MsRefunded
	if allMilestonesTerminal(c) {
		settle(c, StatusCancelled)
	}
	totalLiable -= ms.Amount

	send(cur, c.Client, ms.Amount)

	chain.Emit("RefundClaimed",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"recipient", c.Client.String(),
		"amount", strconv.FormatInt(ms.Amount, 10),
		"status", string(c.Status),
	)
}

// ClaimDisputeTimeout resolves a dispute the admin has not acted on within
// AutoResolveBlks (blocking-window blocks excluded), following the pre-dispute
// status: a delivered milestone (MsCompleted) pays the freelancer minus the
// fee, an undelivered one (MsFunded) refunds the client. Anyone may call.
func ClaimDisputeTimeout(cur realm, contractId string, milestoneIdx int) {
	assertOpen()
	c := getContract(contractId)
	ms := milestoneAt(c, milestoneIdx)
	if ms.Status != MsDisputed {
		panic("milestone not in dispute")
	}
	if ms.DisputedAt == 0 {
		panic("milestone has no dispute record")
	}
	elapsed := elapsedOpen(ms.DisputedAt, ms.disputedPauseMark)
	if elapsed < AutoResolveBlks {
		panic(ufmt.Sprintf("too early: %d blocks remaining", AutoResolveBlks-elapsed))
	}

	payToFreelancer := ms.PreDisputeStatus == MsCompleted
	if payToFreelancer {
		ms.Status = MsReleased
	} else {
		ms.Status = MsRefunded
	}
	c.Status = StatusActive
	if anyMilestoneDisputed(c) {
		c.Status = StatusDisputed
	}
	if allMilestonesReleased(c) {
		settle(c, StatusCompleted)
	} else if allMilestonesTerminal(c) {
		settle(c, StatusCancelled)
	}
	totalLiable -= ms.Amount

	var p payout
	resolution := "refunded-client-no-delivery"
	if payToFreelancer {
		resolution = "paid-freelancer-work-delivered"
		p = payFreelancer(cur, c, ms.Amount)
	} else {
		send(cur, c.Client, ms.Amount)
		p = payout{net: ms.Amount, recipient: c.Client}
	}
	chain.Emit("DisputeTimedOut",
		"contractId", contractId,
		"milestone", strconv.Itoa(milestoneIdx),
		"resolution", resolution,
		"recipient", p.recipient.String(),
		"amount", strconv.FormatInt(p.net, 10),
		"fee", strconv.FormatInt(p.fee, 10),
		"bps", strconv.FormatInt(p.bps, 10),
		"treasury", p.treasury.String(),
		"status", string(c.Status),
	)
}

// ── Archive ──────────────────────────────────────────────────

// ArchiveContract deletes a settled contract (completed or cancelled, with
// nothing escrowed). Client only. The freed bytes shrink the realm's storage,
// and the chain refunds their storage deposit to the signer of this message
// (see DESIGN.md), so the client, who paid for the contract when creating it,
// gets that deposit back. The id is never reused. The ContractArchived event
// is the permanent record; nothing of the contract stays in realm state.
func ArchiveContract(cur realm, contractId string) {
	assertOpen()
	caller := callerOf(cur)
	c := getContract(contractId)
	if c.Client != caller {
		panic("only client can archive")
	}
	if isOpen(c) {
		panic("contract not settled: status is " + string(c.Status))
	}
	var released, refunded int64
	for _, m := range c.Milestones {
		switch m.Status {
		case MsReleased:
			released += m.Amount
		case MsRefunded:
			refunded += m.Amount
		case MsPending:
		default:
			panic("escrowed funds remain in milestone " + strconv.Itoa(m.ID))
		}
	}
	hash := contentHash(c)

	contracts.Remove(contractId)
	n, _ := strconv.Atoi(contractId)
	clientSlots.Remove(indexKey(c.Client, n))
	if clientActive(c.Client) == 0 {
		clientSlots.Remove(c.Client.String())
	}
	archivedCount++

	// milestone*Total are escrow principal, gross of fees and of the cancel
	// compensation. The storage-deposit refund is not an escrow amount: the
	// chain reports it in its own StorageUnlockEvent.
	chain.Emit("ContractArchived",
		"contractId", contractId,
		"client", c.Client.String(),
		"freelancer", c.Freelancer.String(),
		"status", string(c.Status),
		"milestoneReleasedTotal", strconv.FormatInt(released, 10),
		"milestoneRefundedTotal", strconv.FormatInt(refunded, 10),
		"contentHash", hash,
	)
}

// ── Slots and settlement ─────────────────────────────────────

// isOpen reports whether c still holds an active slot.
func isOpen(c *Contract) bool {
	return c.Status != StatusCompleted && c.Status != StatusCancelled
}

func clientActive(client address) int {
	v, ok := clientSlots.Get(client.String())
	if !ok {
		return 0
	}
	return v.(int)
}

func takeSlot(client address) {
	n := clientActive(client)
	if n >= MaxActivePerClient {
		panic(ufmt.Sprintf("limit of %d active contracts for this client reached", MaxActivePerClient))
	}
	clientSlots.Set(client.String(), n+1)
	activeCount++
}

// settle moves an open contract to a terminal status and releases its slot.
// Terminal statuses are absorbing, so this runs at most once per contract.
func settle(c *Contract, status ContractStatus) {
	if !isOpen(c) {
		panic("contract already settled")
	}
	c.Status = status
	n := clientActive(c.Client)
	if n <= 0 || activeCount <= 0 {
		panic("slot accounting underflow")
	}
	// A zero count is kept until the client archives: the client paid for
	// this tree node, and removing it here would refund its deposit to
	// whoever signs the settling message (a permissionless ClaimRefund
	// caller, the admin, the freelancer).
	clientSlots.Set(c.Client.String(), n-1)
	activeCount--
}

// settleIfFinished settles an open contract whose milestones are all released
// (completed) or all released or refunded (cancelled). A pending, funded,
// completed or disputed milestone keeps it open.
func settleIfFinished(c *Contract) {
	if !isOpen(c) {
		return
	}
	allReleased := true
	for _, m := range c.Milestones {
		if m.Status != MsReleased && m.Status != MsRefunded {
			return
		}
		if m.Status != MsReleased {
			allReleased = false
		}
	}
	if allReleased {
		settle(c, StatusCompleted)
	} else {
		settle(c, StatusCancelled)
	}
}

// ── Payments ─────────────────────────────────────────────────

type payout struct {
	recipient address
	net, fee  int64
	bps       int64
	treasury  address
}

func send(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

// payFreelancer pays amount to the freelancer minus the service fee read live
// from the fee spine, which goes to the treasury.
func payFreelancer(cur realm, c *Contract, amount int64) payout {
	bps, treasury := resolveFee()
	fee := basisPointsFee(amount, bps)
	send(cur, c.Freelancer, amount-fee)
	send(cur, treasury, fee)
	return payout{recipient: c.Freelancer, net: amount - fee, fee: fee, bps: bps, treasury: treasury}
}

// ── Helpers ──────────────────────────────────────────────────

func getContract(id string) *Contract {
	val, exists := contracts.Get(id)
	if !exists {
		panic("contract not found: " + id)
	}
	return val.(*Contract)
}

func milestoneAt(c *Contract, idx int) *Milestone {
	if idx < 0 || idx >= len(c.Milestones) {
		panic("invalid milestone index")
	}
	return &c.Milestones[idx]
}

func allMilestonesReleased(c *Contract) bool {
	for _, m := range c.Milestones {
		if m.Status != MsReleased {
			return false
		}
	}
	return true
}

func anyMilestoneDisputed(c *Contract) bool {
	for _, m := range c.Milestones {
		if m.Status == MsDisputed {
			return true
		}
	}
	return false
}

// allMilestonesTerminal reports whether no milestone holds funds (pending with
// no funds counts as terminal).
func allMilestonesTerminal(c *Contract) bool {
	for _, m := range c.Milestones {
		if m.Status == MsFunded || m.Status == MsCompleted || m.Status == MsDisputed {
			return false
		}
	}
	return true
}

// parseMilestones parses "title1:amount1,title2:amount2". Blank entries are
// skipped; any other malformed entry panics.
func parseMilestones(input string) []Milestone {
	if len(input) > maxMilestonesArgLen {
		panic(ufmt.Sprintf("milestones argument too long: %d/%d bytes", len(input), maxMilestonesArgLen))
	}
	var result []Milestone
	total := int64(0)
	for i, p := range strings.Split(input, ",") {
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
		title = cleanText(title, ufmt.Sprintf("milestone title at position %d", i), MaxTitleLen)
		if strings.TrimSpace(title) == "" {
			panic(ufmt.Sprintf("milestone title at position %d has no visible characters", i))
		}
		amount, err := strconv.ParseInt(strings.TrimSpace(kv[1]), 10, 64)
		if err != nil || amount <= 0 {
			panic(ufmt.Sprintf("invalid milestone amount at position %d: must be positive integer", i))
		}
		if amount < MinMilestoneAmount {
			panic(ufmt.Sprintf("milestone amount too small at position %d: minimum %d ugnot", i, MinMilestoneAmount))
		}
		if amount > 9223372036854775807-total {
			panic("contract total overflows int64")
		}
		total += amount
		result = append(result, Milestone{
			ID:     len(result),
			Title:  title,
			Amount: amount,
			Status: MsPending,
		})
	}
	return result
}

// Time-boxed emergency pause.
//
// Pause (admin) has two effects:
//   - New money stops: CreateContract and FundMilestone abort until Unpause.
//   - Every other state-changing entrypoint (settlement, disputes, timeouts,
//     cancellation, expiry, archive) aborts only during the BLOCKING WINDOW,
//     the first MaxPauseBlks blocks of the pause. After that it reopens even if
//     nobody unpauses.
//
// The timeout clocks (AutoRefundBlks, AutoResolveBlks, UnfundedExpiryBlks) do
// not run inside a blocking window: each deadline moves by the paused blocks
// that fell inside it. After Unpause, a new Pause is refused for
// PauseCooldownBlks, so pause, unpause, pause cannot keep exits shut.
//
// Without the time box one admin key (after the DAO handoff, any single member
// allowed to call the emergency pause) could freeze every exit forever, and
// losing the admin key during a pause would do the same: admin rotation needs
// the admin key.
//
// Admin controls (Pause, Unpause, admin and fee-recipient rotation) are never
// paused.

const (
	// MaxPauseBlks is the blocking window: about 7 days at gnoland-1's
	// observed average of about 3.3 s per block (7*24*3600/3.3 = 183,273).
	MaxPauseBlks = int64(183273)
	// PauseCooldownBlks is the minimum gap between an Unpause and the next
	// Pause, so a pause can hold exits shut at most half of the time.
	PauseCooldownBlks = MaxPauseBlks
)

var (
	paused             bool
	pausedAt           int64 // height of the current pause; 0 when not paused
	pauseCooldownUntil int64 // first height at which Pause is accepted again
	pausedBlocksDone   int64 // blocking-window blocks of finished pauses
)

// PauseInfo is the read-back of the pause state.
type PauseInfo struct {
	Paused        bool  // set by Pause, cleared only by Unpause
	PausedAt      int64 // height of the current pause (0 when not paused)
	ExitsReopenAt int64 // PausedAt + MaxPauseBlks (0 when not paused)
	ExitsOpen     bool  // false only inside a blocking window
	CooldownUntil int64 // first height at which Pause is accepted
	PausedBlocks  int64 // total blocking-window blocks so far (clocks skip them)
}

// PauseState returns the pause state at the current height.
func PauseState() PauseInfo {
	now := runtime.ChainHeight()
	s := PauseInfo{
		Paused:        paused,
		ExitsOpen:     !inBlockingWindow(now),
		CooldownUntil: pauseCooldownUntil,
		PausedBlocks:  pausedBlocksAt(now),
	}
	if paused {
		s.PausedAt = pausedAt
		s.ExitsReopenAt = pausedAt + MaxPauseBlks
	}
	return s
}

// IsPaused reports whether the pause flag is set. Exits may already have
// reopened: see PauseState().ExitsOpen.
func IsPaused() bool { return paused }

// Pause stops new money and, for MaxPauseBlks, every other state change.
// Admin only. Refused while paused and during the cooldown after an Unpause.
func Pause(cur realm) {
	assertAdmin(cur)
	now := runtime.ChainHeight()
	if paused {
		panic("already paused")
	}
	if now < pauseCooldownUntil {
		panic("pause cooldown: next pause allowed at block " + strconv.FormatInt(pauseCooldownUntil, 10))
	}
	paused = true
	pausedAt = now
	chain.Emit("Paused",
		"at", strconv.FormatInt(now, 10),
		"exitsReopenAt", strconv.FormatInt(now+MaxPauseBlks, 10),
	)
}

// Unpause resumes normal operation and starts the cooldown. Admin only.
func Unpause(cur realm) {
	assertAdmin(cur)
	now := runtime.ChainHeight()
	if !paused {
		panic("not paused")
	}
	pausedBlocksDone = pausedBlocksAt(now)
	paused = false
	pausedAt = 0
	pauseCooldownUntil = now + PauseCooldownBlks
	chain.Emit("Unpaused",
		"at", strconv.FormatInt(now, 10),
		"cooldownUntil", strconv.FormatInt(pauseCooldownUntil, 10),
	)
}

// inBlockingWindow reports whether now falls in the first MaxPauseBlks blocks
// of the current pause.
func inBlockingWindow(now int64) bool {
	return paused && now < pausedAt+MaxPauseBlks
}

// pausedBlocksAt returns the blocking-window blocks up to now, finished pauses
// included. Timeout clocks subtract the growth of this value.
func pausedBlocksAt(now int64) int64 {
	total := pausedBlocksDone
	if paused {
		end := now
		if end > pausedAt+MaxPauseBlks {
			end = pausedAt + MaxPauseBlks
		}
		total += end - pausedAt
	}
	return total
}

// assertAcceptsNewMoney guards CreateContract and FundMilestone.
func assertAcceptsNewMoney() {
	if paused {
		panic("realm is paused — no new contracts or funding until unpaused")
	}
}

// assertOpen guards every other state-changing user and admin entrypoint.
func assertOpen() {
	if inBlockingWindow(runtime.ChainHeight()) {
		panic("realm is paused — exits reopen at block " + strconv.FormatInt(pausedAt+MaxPauseBlks, 10))
	}
}

// elapsedOpen returns the blocks since `since` that fell outside any blocking
// window, given pausedBlocksAt(since) recorded as mark.
func elapsedOpen(since, mark int64) int64 {
	now := runtime.ChainHeight()
	return now - since - (pausedBlocksAt(now) - mark)
}

// ── Admin authority and the fallback fee recipient ──────────────────────
//
// No authority is compiled in. `admin` and `feeRecipient` are seeded at
// package load from the publishing transaction's signer (on gnoland-1 the
// samcrew namespace multisig), and every gate reads the mutable variables.
// Realms are immutable and mainnet has no faucet, so a compile-time authority
// could never be corrected; losing it would disable Pause/Unpause and
// ResolveDispute, the only path that settles a dispute before its timeout.
//
// Both rotations are TWO-STEP: the current admin stages an address, and that
// address must accept with its own transaction. A one-step setter could hand
// the role to an address that cannot act (a typo, an unfunded key), with no
// way back. The admin can abort a staged proposal without the target.
//
// Rotation stays available while paused. It needs the current admin key, so
// it cannot rescue a pause after that key is lost; the pause's time box
// (pause section above) is what keeps exits from freezing.

var (
	// admin is the live authority, seeded with the publisher at load.
	admin address = publisherAtLoad()
	// pendingAdmin is the staged successor; "" when none.
	pendingAdmin address

	// feeRecipient receives the protocol fee only when memba_market_config
	// reports no treasury (see resolveFee). Seeded with the publisher.
	feeRecipient address = publisherAtLoad()
	// pendingFeeRecipient is the staged successor; "" when none.
	pendingFeeRecipient address
)

// assertAdmin rejects a stale or sibling `cur`, then checks the caller.
func assertAdmin(cur realm) {
	if callerOf(cur) != admin {
		panic("unauthorized: only admin may perform this action")
	}
}

// ── Admin rotation ───────────────────────────────────────────

// TransferOwnership stages a handoff to newAdmin. Admin only. Calling it again
// replaces the staged address.
func TransferOwnership(cur realm, newAdmin address) {
	assertAdmin(cur)
	if !newAdmin.IsValid() {
		panic("newAdmin must be a valid address")
	}
	pendingAdmin = newAdmin
	chain.Emit("OwnershipTransferStarted", "pending", newAdmin.String())
}

// AcceptOwnership completes the handoff. Only the staged address may call it,
// so the outgoing admin cannot collapse the two steps into one.
func AcceptOwnership(cur realm) {
	caller := callerOf(cur)
	if pendingAdmin == "" {
		panic("no pending ownership transfer")
	}
	if caller != pendingAdmin {
		panic("unauthorized: only the pending admin may accept")
	}
	admin = pendingAdmin
	pendingAdmin = ""
	chain.Emit("OwnershipTransferAccepted", "admin", admin.String())
}

// CancelOwnershipTransfer clears a staged handoff. Admin only.
func CancelOwnershipTransfer(cur realm) {
	assertAdmin(cur)
	if pendingAdmin == "" {
		panic("no pending ownership transfer")
	}
	cancelled := pendingAdmin
	pendingAdmin = ""
	chain.Emit("OwnershipTransferCancelled", "cancelled", cancelled.String())
}

// GetAdmin returns the address that holds admin.
func GetAdmin() string { return admin.String() }

// GetPendingAdmin returns the staged successor ("" when none).
func GetPendingAdmin() string { return pendingAdmin.String() }

// ── Fee recipient rotation ───────────────────────────────────

// ProposeFeeRecipient stages a new fallback fee recipient. Admin only.
func ProposeFeeRecipient(cur realm, recipient address) {
	assertAdmin(cur)
	if !recipient.IsValid() {
		panic("fee recipient must be a valid address")
	}
	pendingFeeRecipient = recipient
	chain.Emit("FeeRecipientProposed", "pending", recipient.String())
}

// AcceptFeeRecipient completes the rotation. Only the staged address may call
// it, which proves it can transact.
func AcceptFeeRecipient(cur realm) {
	caller := callerOf(cur)
	if pendingFeeRecipient == "" {
		panic("no pending fee recipient")
	}
	if caller != pendingFeeRecipient {
		panic("unauthorized: only the pending fee recipient may accept")
	}
	feeRecipient = pendingFeeRecipient
	pendingFeeRecipient = ""
	chain.Emit("FeeRecipientAccepted", "recipient", feeRecipient.String())
}

// CancelFeeRecipientProposal clears a staged fee recipient. Admin only.
func CancelFeeRecipientProposal(cur realm) {
	assertAdmin(cur)
	if pendingFeeRecipient == "" {
		panic("no pending fee recipient")
	}
	cancelled := pendingFeeRecipient
	pendingFeeRecipient = ""
	chain.Emit("FeeRecipientProposalCancelled", "cancelled", cancelled.String())
}

// GetFeeRecipient returns the fallback fee recipient.
func GetFeeRecipient() string { return feeRecipient.String() }

// GetPendingFeeRecipient returns the staged fee recipient ("" when none).
func GetPendingFeeRecipient() string { return pendingFeeRecipient.String() }

// basisPointsFee computes floor(amount*bps/10000) without overflowing the
// intermediate product. For nonnegative amount and bps <= 10000, the quotient
// product and final sum are <= amount; the remainder product is < 100000000.
// Callers retain their existing configured rates, recipients and rounding.
func basisPointsFee(amount, bps int64) int64 {
	if amount < 0 || bps < 0 || bps > 10000 {
		panic("invalid fee inputs")
	}
	return (amount/10000)*bps + ((amount%10000)*bps)/10000
}

// cleanText validates and sanitises user text before it is stored and
// rendered. It refuses input longer than max bytes, input that is not valid
// UTF-8 (the sanitiser would otherwise turn each bad byte into a 3-byte
// U+FFFD, storing up to three times the limit), and control or format
// characters (\p{Cc}, \p{Cf}: bidi overrides, zero-width characters), which
// could hide or reorder text. It then strips markdown-sensitive characters and
// line breaks and tabs, as v3 did. Stripping only removes bytes, so the result
// is within max; that is checked again because storage is bounded by it.
func cleanText(s, what string, max int) string {
	if len(s) > max {
		panic(ufmt.Sprintf("%s must be at most %d bytes", what, max))
	}
	if !utf8.ValidString(s) {
		panic(what + " must be valid UTF-8")
	}
	strip := false
	for _, c := range s {
		if isStripped(c) {
			strip = true
			continue
		}
		if c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0) || (mayBeFormat(c) && unicode.Is(unicode.Cf, c)) {
			panic(what + " contains invisible or control characters")
		}
	}
	if !strip {
		return s
	}
	var out strings.Builder
	for _, c := range s {
		if !isStripped(c) {
			out.WriteRune(c)
		}
	}
	clean := out.String()
	if len(clean) > max {
		panic(ufmt.Sprintf("%s must be at most %d bytes", what, max))
	}
	return clean
}

// isStripped reports the markdown-sensitive characters and line breaks and
// tabs removed from stored text, as in v3.
func isStripped(c rune) bool {
	switch c {
	case '[', ']', '(', ')', '#', '*', '`', '!', '<', '>', '|', '\\', '_', '~', '\n', '\r', '\t':
		return true
	}
	return false
}

// mayBeFormat is a cheap superset test for \p{Cf} (every format character is
// U+00AD, in U+0600..U+206F, or at or above U+FEFF), so common text skips the
// table lookup.
func mayBeFormat(c rune) bool {
	return c == 0xad || (c >= 0x600 && c <= 0x206f) || c >= 0xfeff
}
