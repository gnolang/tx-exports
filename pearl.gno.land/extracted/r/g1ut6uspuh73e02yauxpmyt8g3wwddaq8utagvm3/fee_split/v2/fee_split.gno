package fee_split

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"sort"
	"strconv"
	"strings"
)

// Split holds a fee-splitting configuration with percentage-based shares
// denominated in basis points (1 bp = 0.01%, 10000 bp = 100%).
type Split struct {
	Owner          address
	PendingOwner   address // two-step handover, must AcceptOwnership
	Recipients     []address
	Shares         []int64 // basis points, must sum to 10000
	Balances       map[address]int64
	TotalDeposited int64
	TotalClaimed   int64
	Frozen         bool
	Archived       bool
}

const (
	MaxRecipients     = 20
	MaxSplitsPerOwner = 10
	// Quotas are PER-OWNER only (round-4 audit): a global cap is a shared
	// resource 50 sybil accounts could fill forever — and seeding grief
	// splits with balances to keyless recipients made the fill
	// unrecoverable even by the sybils. Per-owner quotas mean an attacker
	// consumes only their own budget; state growth is gas-priced.
	// Render is bounded separately (MaxRenderSplits).
	MaxRenderSplits = 100
	// MaxFeeBps is an IMMUTABLE ceiling on the protocol fee (1%). The
	// admin can set any fee from 0 up to this cap, never above it — the
	// cap, not the current setting, is what users must trust.
	MaxFeeBps = int64(100)

	// Pre-parse input bounds (round-4 audit): caps were enforced only
	// AFTER full parsing, so a 1MB recipient list burned ~11B gas before
	// refusal. 20 bech32 addresses + separators fit well within these.
	MaxRecipientListLen = 1024
	MaxShareListLen     = 128

	// Denomination handled by this realm. Deposits must be exactly one
	// coin of this denom; claims pay out in it.
	Denom = "ugnot"

	// Largest single deposit for which share math (amount * share,
	// share <= 10000) cannot overflow int64.
	MaxDepositAmount = int64(9223372036854775807) / 10000
)

var (
	splits      map[string]*Split
	splitIDs    []string // insertion-ordered for deterministic Render
	ownerSplits map[address]int
	nextID      int

	// Protocol fee: taken from each deposit BEFORE distribution, at the
	// rate in force at deposit time (never retroactive — credited
	// balances are never touched). Defaults to zero.
	feeBps          int64
	feeAdmin        address // deployer; can set the fee and claim accrued fees
	pendingFeeAdmin address // two-step handover, must AcceptFeeAdmin
	feesAccrued     int64
	feesClaimed     int64
)

func init() {
	splits = make(map[string]*Split)
	splitIDs = []string{}
	ownerSplits = make(map[address]int)
	nextID = 1
	// The package deployer becomes the fee admin: on-chain, AddPackage
	// runs init with the message creator as origin caller (verified
	// against the VM keeper — a MsgAddPackage's creator is never zero).
	// If OriginCaller() were ever empty (e.g. the gno test VM, which has
	// no MsgAddPackage), the fee feature degrades SAFELY to disabled:
	// SetFee requires the runtime-derived caller to equal feeAdmin and
	// that caller is never empty, so
	// feeBps can never leave 0 and no fee ever accrues — zero funds at
	// risk. Do not "harden" this into a panic; the soft-disable is the
	// safe behavior. Fee starts at ZERO regardless.
	feeAdmin = unsafe.OriginCaller()
	feeBps = 0
}

// ---------- helpers ----------

func formatPct(bp int64) string {
	whole := strconv.FormatInt(bp/100, 10)
	frac := strconv.FormatInt(bp%100, 10)
	if len(frac) == 1 {
		frac = "0" + frac
	}
	return whole + "." + frac + "%"
}

func mustGetSplit(id string) *Split {
	s, ok := splits[id]
	if !ok {
		panic("split not found: " + id)
	}
	return s
}

func mustGetActive(id string) *Split {
	s := mustGetSplit(id)
	if s.Archived {
		panic("split is archived: " + id)
	}
	return s
}

func boolStr(v bool) string {
	if v {
		return "yes"
	}
	return "no"
}

func parseBasisPoints(raw string) []int64 {
	if len(raw) > MaxShareListLen {
		panic("share list too long")
	}
	parts := strings.Split(raw, ",")
	out := make([]int64, len(parts))
	var total int64
	for i, s := range parts {
		v, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil || v <= 0 || v > 10000 {
			// the upper bound is a security invariant, not hygiene: unbounded
			// shares let the int64 total wrap back to exactly 10000, minting
			// unbacked balances paid from the shared pool (re-audit P1)
			panic("invalid share value: " + strings.TrimSpace(s))
		}
		out[i] = int64(v)
		total += int64(v)
	}
	if total != 10000 {
		panic("shares must sum to 10000 basis points, got " + strconv.FormatInt(total, 10))
	}
	return out
}

func parseAddresses(raw string) []address {
	if len(raw) > MaxRecipientListLen {
		panic("recipient list too long")
	}
	parts := strings.Split(raw, ",")
	out := make([]address, len(parts))
	for i, r := range parts {
		a := address(strings.TrimSpace(r))
		if a == "" {
			panic("empty recipient address at position " + strconv.Itoa(i))
		}
		if !a.IsValid() || string(a) != strings.ToLower(string(a)) {
			// lowercase is required, not cosmetic (round-3 audit): bech32
			// accepts ALL-UPPERCASE as valid, but the runtime always returns
			// the lowercase canonical form — an uppercase-keyed balance
			// could never be claimed and would block Archive forever, and
			// upper/lower duplicates would bypass the duplicate check
			panic("invalid recipient address: " + string(a))
		}
		// NOTE: IsValid is a format check only — a well-formed address with
		// no key holder (e.g. another package's derived address) will
		// accumulate a balance nobody can claim, which also blocks Archive
		// forever. Owners must list addresses they know can call Claim.
		out[i] = a
	}
	return out
}

func validateRecipients(recipients []address, shares []int64) {
	if len(recipients) != len(shares) {
		panic("recipients and shares must have the same length")
	}
	if len(recipients) == 0 {
		panic("at least one recipient is required")
	}
	if len(recipients) > MaxRecipients {
		panic("too many recipients (max " + strconv.Itoa(MaxRecipients) + ")")
	}
	seen := make(map[address]bool)
	for _, r := range recipients {
		if seen[r] {
			panic("duplicate recipient: " + string(r))
		}
		seen[r] = true
	}
}

// sortedBalanceAddrs returns the balance-map keys in deterministic order,
// so panics and renders never depend on map iteration order.
func sortedBalanceAddrs(s *Split) []string {
	addrs := make([]string, 0, len(s.Balances))
	for a := range s.Balances {
		addrs = append(addrs, string(a))
	}
	sort.Strings(addrs)
	return addrs
}

// rejectStraySend aborts when coins are attached to a call that does not
// accept them — the abort reverts the transfer back to the sender instead
// of stranding the coins on the realm address (re-audit P3). Direct bank
// transfers to the realm address remain unrecoverable by design.
func rejectStraySend(cur realm) {
	if !cur.IsCurrent() {
		// every call site passes the entrypoint's own first cur; this
		// pins that discipline against future call-site drift (v2
		// audit G3 hardening)
		panic("realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this function does not accept coins; attach coins to Deposit only")
	}
}

// ---------- write operations ----------

// CreateSplit registers a new split. The caller becomes the owner.
// Recipients and shares are comma-separated; shares are in basis points
// summing to 10000.
func CreateSplit(cur realm, recipientList, shareList string) string {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	if ownerSplits[owner] >= MaxSplitsPerOwner {
		panic("per-owner split limit reached")
	}

	recipients := parseAddresses(recipientList)
	shares := parseBasisPoints(shareList)
	validateRecipients(recipients, shares)

	id := "split_" + strconv.Itoa(nextID)
	nextID++

	balances := make(map[address]int64)
	for _, r := range recipients {
		balances[r] = 0
	}

	splits[id] = &Split{
		Owner:      owner,
		Recipients: recipients,
		Shares:     shares,
		Balances:   balances,
	}
	splitIDs = append(splitIDs, id)
	ownerSplits[owner]++
	return id
}

// Deposit distributes the coins sent with the call across recipients
// proportionally.
//
// DEPLOYMENT PRECONDITION (round-4 audit): on a network with
// restricted/token-locked ugnot transfers, the bank gate is
// SENDER-whitelist-based — a whitelisted user's Deposit succeeds but
// Claim sends FROM this realm's (non-whitelisted) address and reverts.
// Funds would flow in and not out until the restriction lifts. Deploy
// only to networks with unrestricted ugnot, or have governance
// whitelist this realm's address first.
//
// LIMITATION (round-3 audit, documented): only direct user calls can
// deposit. A DAO/realm treasury has NO deposit path — a realm-routed
// call is refused, and a bare banker send to this realm's address is
// an unrecoverable donation. Realm treasuries must route deposits
// through a user account. The deposit is the ACTUAL attached send — exactly one
// coin of Denom — so balances are always backed by funds this realm
// holds. Direct user calls only: a deposit routed through an
// intermediary realm would deliver its coins to that realm, not here,
// and must be rejected. Rounding dust goes to the highest-share
// recipient (deterministic, not order-dependent).
func Deposit(cur realm, splitID string) {
	s := mustGetActive(splitID)
	if s.Frozen {
		panic("split is frozen")
	}

	// IsUserCall, not IsUser: MsgRun passes IsUser but its attached send
	// goes caller->caller — the coins never reach this realm, and OriginSend
	// could be re-read across k calls in one run script (re-audit P1). A
	// direct MsgCall's send provably lands on the called package address.
	if !cur.Previous().IsUserCall() {
		panic("deposits must be sent by direct call, not through another realm or a run script")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("deposit must send exactly one coin of " + Denom)
	}
	amount := sent[0].Amount
	if amount <= 0 {
		panic("amount must be greater than zero")
	}
	if amount > MaxDepositAmount {
		panic("deposit exceeds maximum supported amount")
	}
	if s.TotalDeposited > int64(9223372036854775807)-amount {
		panic("deposit would overflow split accounting")
	}

	// Protocol fee comes off the top; everything below distributes the
	// NET amount, so the per-split conservation invariant
	// (sum(balances)+TotalClaimed == TotalDeposited) is untouched.
	// amount <= MaxDepositAmount and feeBps <= 100, so the product is
	// far below overflow.
	fee := (amount * feeBps) / 10000
	if fee > 0 {
		if feesAccrued > int64(9223372036854775807)-fee {
			panic("fee accrual would overflow")
		}
		feesAccrued += fee
		amount -= fee
	}
	if amount == 0 {
		panic("deposit too small: fully consumed by the protocol fee")
	}

	s.TotalDeposited += amount

	// Find the highest-share recipient for dust assignment
	dustIdx := 0
	for i := 1; i < len(s.Shares); i++ {
		if s.Shares[i] > s.Shares[dustIdx] {
			dustIdx = i
		}
	}

	var distributed int64
	for i, r := range s.Recipients {
		share := (amount * s.Shares[i]) / 10000
		s.Balances[r] += share
		distributed += share
	}

	// Assign dust to highest-share recipient
	dust := amount - distributed
	if dust > 0 {
		s.Balances[s.Recipients[dustIdx]] += dust
	}
}

// Claim withdraws the caller's accumulated balance and SENDS the coins
// to the caller's address. Balance is zeroed before the transfer.
// Claims remain possible on frozen splits, and by ex-recipients whose
// accrued balance predates a share update.
func Claim(cur realm, splitID string) int64 {
	rejectStraySend(cur)
	s := mustGetActive(splitID)
	addr := cur.Previous().Address()

	bal, exists := s.Balances[addr]
	if !exists {
		panic("not a recipient of this split")
	}
	if bal == 0 {
		panic("nothing to claim")
	}

	s.Balances[addr] = 0
	s.TotalClaimed += bal

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), addr,
		chain.Coins{{Denom: Denom, Amount: bal}})
	return bal
}

// UpdateShares replaces recipients and shares. Owner only. Not if frozen.
// Removed recipients keep any accrued balance and can still Claim it.
func UpdateShares(cur realm, splitID, recipientList, shareList string) {
	rejectStraySend(cur)
	s := mustGetActive(splitID)
	if cur.Previous().Address() != s.Owner {
		panic("only the owner can update shares")
	}
	if s.Frozen {
		panic("split is frozen")
	}

	recipients := parseAddresses(recipientList)
	shares := parseBasisPoints(shareList)
	validateRecipients(recipients, shares)

	for _, r := range recipients {
		if _, ok := s.Balances[r]; !ok {
			s.Balances[r] = 0
		}
	}

	s.Recipients = recipients
	s.Shares = shares
}

// TransferOwnership stages a two-step ownership handover; nothing
// moves until the nominee calls AcceptOwnership. Two-step for the same
// reason as the fee admin, plus one more (v2 audit Y1): a one-step
// transfer consumed the RECIPIENT's per-owner quota without consent,
// so poisoned splits could burn a victim's slots unarchivably. Staging
// consumes nothing of the nominee's. Pass "" to clear a pending
// nomination.
func TransferOwnership(cur realm, splitID string, newOwner address) {
	rejectStraySend(cur)
	s := mustGetActive(splitID)
	if cur.Previous().Address() != s.Owner {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" {
		s.PendingOwner = ""
		return
	}
	if !newOwner.IsValid() || string(newOwner) != strings.ToLower(string(newOwner)) {
		// see parseAddresses: an uppercase owner could never match the
		// runtime-derived caller again — the split would be owner-less
		panic("invalid new owner address: " + string(newOwner))
	}
	if newOwner == s.Owner {
		panic("new owner is already the owner")
	}
	s.PendingOwner = newOwner
}

// AcceptOwnership completes the handover; only the nominee can accept.
// The nominee's quota is checked HERE, at consent time — the split
// slot moves only with the acceptor's own signature (v2 audit Y1: a
// recipient's quota is never consumed without consent). A nomination
// on a split that is later archived is inert (mustGetActive).
func AcceptOwnership(cur realm, splitID string) {
	rejectStraySend(cur)
	s := mustGetActive(splitID)
	caller := cur.Previous().Address()
	if s.PendingOwner == "" || caller != s.PendingOwner {
		panic("caller is not the pending owner")
	}
	if ownerSplits[caller] >= MaxSplitsPerOwner {
		panic("new owner is at the per-owner split limit")
	}

	ownerSplits[s.Owner]--
	if ownerSplits[s.Owner] <= 0 {
		delete(ownerSplits, s.Owner)
	}
	ownerSplits[caller]++
	s.Owner = caller
	s.PendingOwner = ""
}

// Freeze permanently locks shares and stops further deposits. One-way,
// cannot be undone. Claims remain possible.
func Freeze(cur realm, splitID string) {
	rejectStraySend(cur)
	s := mustGetActive(splitID)
	if cur.Previous().Address() != s.Owner {
		panic("only the owner can freeze")
	}
	s.Frozen = true
}

// Archive marks a fully-claimed split as archived. Only the owner can
// archive, and only if EVERY balance — including balances held by
// ex-recipients removed in a share update — is zero, since archiving
// blocks all further claims. Cannot be undone.
func Archive(cur realm, splitID string) {
	rejectStraySend(cur)
	s := mustGetActive(splitID)
	if cur.Previous().Address() != s.Owner {
		panic("only the owner can archive")
	}

	for _, a := range sortedBalanceAddrs(s) {
		if s.Balances[address(a)] > 0 {
			panic("cannot archive: outstanding balance for " + a)
		}
	}

	s.Archived = true

	// Free the owner's slot so they can create new splits
	ownerSplits[s.Owner]--
	if ownerSplits[s.Owner] <= 0 {
		delete(ownerSplits, s.Owner)
	}

	// Remove from active ID list (keeps map entry for audit)
	for i, id := range splitIDs {
		if id == splitID {
			splitIDs = append(splitIDs[:i], splitIDs[i+1:]...)
			break
		}
	}
}

// ---------- protocol fee ----------

// SetFee sets the protocol fee in basis points, admin only, hard-capped
// at MaxFeeBps. Applies to FUTURE deposits only.
func SetFee(cur realm, bps int64) {
	rejectStraySend(cur)
	if cur.Previous().Address() != feeAdmin {
		panic("only the fee admin can set the fee")
	}
	if bps < 0 || bps > MaxFeeBps {
		panic("fee must be between 0 and " + strconv.FormatInt(MaxFeeBps, 10) + " basis points")
	}
	feeBps = bps
}

// ClaimFees sends all accrued protocol fees to the fee admin.
func ClaimFees(cur realm) int64 {
	rejectStraySend(cur)
	if cur.Previous().Address() != feeAdmin {
		panic("only the fee admin can claim fees")
	}
	if feesAccrued == 0 {
		panic("no fees accrued")
	}
	amount := feesAccrued
	feesAccrued = 0
	feesClaimed += amount

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), feeAdmin,
		chain.Coins{{Denom: Denom, Amount: amount}})
	return amount
}

// NominateFeeAdmin begins a two-step admin handover; the nominee must
// AcceptFeeAdmin. Pass "" to clear a pending nomination. Two-step
// because the admin address is a funds destination: a typo'd one-step
// transfer would strand all future fees.
func NominateFeeAdmin(cur realm, nominee address) {
	rejectStraySend(cur)
	if cur.Previous().Address() != feeAdmin {
		panic("only the fee admin can nominate a successor")
	}
	if nominee == "" {
		pendingFeeAdmin = ""
		return
	}
	if !nominee.IsValid() || string(nominee) != strings.ToLower(string(nominee)) {
		panic("invalid nominee address: " + string(nominee))
	}
	pendingFeeAdmin = nominee
}

// AcceptFeeAdmin completes the handover; only the nominee can accept.
func AcceptFeeAdmin(cur realm) {
	rejectStraySend(cur)
	if pendingFeeAdmin == "" || cur.Previous().Address() != pendingFeeAdmin {
		panic("caller is not the pending fee admin")
	}
	feeAdmin = pendingFeeAdmin
	pendingFeeAdmin = ""
}

// GetFeeInfo returns the current fee configuration and accrued total.
func GetFeeInfo() string {
	return "fee: " + formatPct(feeBps) + " (cap " + formatPct(MaxFeeBps) +
		") | admin: " + string(feeAdmin) +
		" | accrued: " + strconv.FormatInt(feesAccrued, 10) +
		" | claimed: " + strconv.FormatInt(feesClaimed, 10)
}

// ---------- read-only queries ----------

// GetSplitInfo returns a human-readable summary.
func GetSplitInfo(splitID string) string {
	s := mustGetSplit(splitID)

	var b strings.Builder
	b.WriteString("Split: " + splitID + "\n")
	b.WriteString("Owner: " + string(s.Owner) + "\n")
	if s.PendingOwner != "" {
		// a nominee must be able to READ the offer before spending gas
		// probing it with AcceptOwnership (v2 audit Y1-obs)
		b.WriteString("Pending owner: " + string(s.PendingOwner) + "\n")
	}
	b.WriteString("Frozen: " + boolStr(s.Frozen) + "\n")
	b.WriteString("Archived: " + boolStr(s.Archived) + "\n")
	b.WriteString("Total deposited: " + strconv.FormatInt(s.TotalDeposited, 10) + "\n")
	b.WriteString("Total claimed: " + strconv.FormatInt(s.TotalClaimed, 10) + "\n")
	b.WriteString("Recipients:\n")
	for i, r := range s.Recipients {
		b.WriteString("  " + string(r) + "  " + formatPct(s.Shares[i]) + "  claimable: " + strconv.FormatInt(s.Balances[r], 10) + "\n")
	}
	return b.String()
}

// GetPendingOwner returns the staged nominee for a split, or "" when no
// handover is pending. The consent half of a two-step transfer only means
// something if the nominee can inspect the offer without paying gas to
// probe it (v2 audit Y1-obs); this is that read path.
func GetPendingOwner(splitID string) string {
	return string(mustGetSplit(splitID).PendingOwner)
}

// GetClaimable returns claimable balance for an address.
func GetClaimable(splitID string, addr address) int64 {
	s := mustGetSplit(splitID)
	return s.Balances[addr]
}

// ---------- render ----------

// Render returns a markdown overview. Never panics.
func Render(path string) string {
	if len(splitIDs) == 0 {
		return "# Fee Split\n\nNo active splits.\n"
	}

	var b strings.Builder
	b.WriteString("# Fee Split\n\n")
	if feeBps > 0 {
		b.WriteString("**Protocol fee:** " + formatPct(feeBps) + " (hard cap " + formatPct(MaxFeeBps) + ")\n\n")
	}

	show := splitIDs
	if len(show) > MaxRenderSplits {
		b.WriteString("_Showing the most recent " + strconv.Itoa(MaxRenderSplits) + " active splits._\n\n")
		show = show[len(show)-MaxRenderSplits:]
	}
	for _, id := range show {
		s := splits[id]
		b.WriteString("## " + id + "\n\n")
		if s == nil {
			b.WriteString("_(invalid)_\n\n")
			continue
		}
		b.WriteString("```\n")
		b.WriteString("Owner: " + string(s.Owner) + "\n")
		if s.PendingOwner != "" {
			b.WriteString("Pending owner: " + string(s.PendingOwner) + "\n")
		}
		b.WriteString("Frozen: " + boolStr(s.Frozen) + "\n")
		b.WriteString("Total deposited: " + strconv.FormatInt(s.TotalDeposited, 10) + "\n")
		b.WriteString("Total claimed: " + strconv.FormatInt(s.TotalClaimed, 10) + "\n")
		if len(s.Recipients) > 0 {
			b.WriteString("Recipients:\n")
			for i, r := range s.Recipients {
				share := "??%"
				if i < len(s.Shares) {
					share = formatPct(s.Shares[i])
				}
				bal := "0"
				if s.Balances != nil {
					bal = strconv.FormatInt(s.Balances[r], 10)
				}
				b.WriteString("  " + string(r) + "  " + share + "  claimable: " + bal + "\n")
			}
		}
		b.WriteString("```\n\n")
	}
	return b.String()
}
