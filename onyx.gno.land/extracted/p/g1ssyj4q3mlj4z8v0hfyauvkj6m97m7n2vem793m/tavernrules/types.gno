// Package tavernrules holds the pure rules of BugTavern.
//
// Pure means: no coins, no chain, no storage. Every function here takes
// its inputs as plain arguments (actor addresses, block heights) so it
// can be unit-tested with `gno test` and no node.
//
// Design reference: BugTavern-DESIGN.md §4. All struct fields are
// private; only the move methods in this package may change them.
// Readers return value copies, never pointers into stored state.
//
// Money invariants (design §4.2), checked by Bounty.CheckInvariant:
//   - poolLeft + paidOut + refunded == poolTotal
//   - poolLeft >= 0, and a payout only happens when poolLeft >= amount
//   - no Open bounty with deadline < createdAt
//   - no finding with revealDeadline <= committedAt
package tavernrules

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// Limits (design §3.4) and windows (design §6.3).
// Lengths are byte lengths: storage deposit is charged per byte.
// ---------------------------------------------------------------------------

const (
	// MaxTitleLen is the longest bounty/finding title.
	MaxTitleLen = 100
	// MaxScopeLen is the longest bounty scope/description.
	MaxScopeLen = 1000
	// MaxPocURLLen is the longest PoC URL.
	MaxPocURLLen = 300
	// MaxReasonLen is the longest reject/dispute reason.
	MaxReasonLen = 300
	// MinBountyReward is the smallest poolTotal of a bounty (1 GNOT).
	MinBountyReward int64 = 1000000
	// MinTierPrice is the smallest price of one severity tier (0.1 GNOT).
	MinTierPrice int64 = 100000
	// MinSaltLen is the shortest reveal salt (entropy cannot be checked
	// on-chain, only length — see MakeCommitment).
	MinSaltLen = 16
	// CommitHashLen is the length of a lowercase hex sha256 digest.
	CommitHashLen = 64
)

const (
	// RevealWindow blocks (~24h at ~3.5s/block) to reveal after commit.
	RevealWindow int64 = 24600
	// ReviewWindow blocks (~3 days) for the arbiter to give a verdict.
	ReviewWindow int64 = 72000
	// SponsorWindow blocks (~3 days) for the sponsor verdict after the
	// arbiter's window expires.
	SponsorWindow int64 = 72000
	// DisputeWindow blocks (~36h) for the hunter to dispute a rejection.
	DisputeWindow int64 = 36000
	// FixWindow blocks (~14 days) after which an Accepted finding
	// becomes Disclosed even without MarkFixed.
	FixWindow int64 = 345600
)

// MaxInt64 is the largest int64 value, for checked math.
const MaxInt64 int64 = 9223372036854775807

// ---------------------------------------------------------------------------
// Checked math (design §7 T11). Gno integers wrap silently, so every
// addition that touches money must go through these helpers.
// ---------------------------------------------------------------------------

// CheckedAdd returns a+b and true, or 0 and false on overflow.
func CheckedAdd(a, b int64) (int64, bool) {
	if b > 0 && a > MaxInt64-b {
		return 0, false
	}
	if b < 0 && a < -MaxInt64-1-b {
		return 0, false
	}
	return a + b, true
}

// CheckedSub returns a-b and true, or 0 and false on overflow.
func CheckedSub(a, b int64) (int64, bool) {
	if b < 0 && a > MaxInt64+b {
		return 0, false
	}
	if b > 0 && a < -MaxInt64-1+b {
		return 0, false
	}
	return a - b, true
}

// ---------------------------------------------------------------------------
// Severity
// ---------------------------------------------------------------------------

// Severity is the reward tier of a finding.
type Severity uint8

const (
	SevLow Severity = iota + 1
	SevMedium
	SevHigh
	SevCritical
)

// Valid reports whether s is one of the four tiers.
func (s Severity) Valid() bool {
	return s >= SevLow && s <= SevCritical
}

// String returns the tier name (for Render and events).
func (s Severity) String() string {
	switch s {
	case SevLow:
		return "Low"
	case SevMedium:
		return "Medium"
	case SevHigh:
		return "High"
	case SevCritical:
		return "Critical"
	default:
		return "Unknown"
	}
}

// ---------------------------------------------------------------------------
// BountyStatus
// ---------------------------------------------------------------------------

// BountyStatus is the lifecycle state of a bounty.
type BountyStatus uint8

const (
	BountyOpen BountyStatus = iota + 1
	// BountyClosed is final: pool spent, or deadline passed and the
	// remainder refunded.
	BountyClosed
	// BountyCancelled is final: sponsor cancelled while no finding was
	// in flight, remainder refunded.
	BountyCancelled
)

// Valid reports whether s is a known bounty status.
func (s BountyStatus) Valid() bool {
	return s >= BountyOpen && s <= BountyCancelled
}

// String returns the status name.
func (s BountyStatus) String() string {
	switch s {
	case BountyOpen:
		return "Open"
	case BountyClosed:
		return "Closed"
	case BountyCancelled:
		return "Cancelled"
	default:
		return "Unknown"
	}
}

// ---------------------------------------------------------------------------
// FindingStatus
// ---------------------------------------------------------------------------

// FindingStatus is the lifecycle state of a finding.
type FindingStatus uint8

const (
	FindingCommitted FindingStatus = iota + 1 // hash only, not revealed
	FindingRevealed                           // revealed, awaiting verdict
	FindingAccepted                           // final: paid
	FindingDuplicate                          // final: duplicate, not paid
	FindingRejected                           // final unless disputed
	FindingDisputed                           // rejection disputed, awaiting re-verdict
	FindingDisclosed                          // final: accepted and publicly disclosed
	FindingExpired                            // final: commit lapsed past revealDeadline, never revealed
)

// Valid reports whether s is a known finding status.
func (s FindingStatus) Valid() bool {
	return s >= FindingCommitted && s <= FindingExpired
}

// IsFinal reports whether no further move is allowed from this status.
func (s FindingStatus) IsFinal() bool {
	switch s {
	case FindingAccepted, FindingDuplicate, FindingDisclosed, FindingExpired:
		return true
	case FindingRejected:
		// Rejected is final only once the dispute window has passed;
		// that is a height check, not a status property.
		return false
	default:
		return false
	}
}

// String returns the status name.
func (s FindingStatus) String() string {
	switch s {
	case FindingCommitted:
		return "Committed"
	case FindingRevealed:
		return "Revealed"
	case FindingAccepted:
		return "Accepted"
	case FindingDuplicate:
		return "Duplicate"
	case FindingRejected:
		return "Rejected"
	case FindingDisputed:
		return "Disputed"
	case FindingDisclosed:
		return "Disclosed"
	case FindingExpired:
		return "Expired"
	default:
		return "Unknown"
	}
}

// ---------------------------------------------------------------------------
// Commit-reveal (design §4.1).
// GATE DAY 1 — VERIFIED: crypto/sha256 exposes ONLY Sum256 in gno
// v1.8.0 (sha256.New does NOT exist — see gate report in README).
// Sum256 + encoding/hex is sufficient: the commitment is a one-shot
// hash, no streaming hash.Hash is needed. Full commit-reveal stands.
// ---------------------------------------------------------------------------

// MakeCommitment returns sha256_hex(bountyID|severity|title|pocURL|salt)
// with decimal integers and "|" separators, in fixed field order.
// The realm recomputes this at reveal and compares it to the stored
// commitHash; a mismatch panics.
func MakeCommitment(bountyID uint64, severity Severity, title, pocURL, salt string) string {
	preimage := strconv.FormatUint(bountyID, 10) + "|" +
		strconv.Itoa(int(severity)) + "|" +
		title + "|" + pocURL + "|" + salt
	sum := sha256.Sum256([]byte(preimage))
	return hex.EncodeToString(sum[:])
}

// ValidateCommitHash returns "" when h is a 64-char lowercase hex digest.
func ValidateCommitHash(h string) string {
	if len(h) != CommitHashLen {
		return "commit hash must be 64 hex chars"
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return "commit hash must be lowercase hex"
		}
	}
	return ""
}

// ValidateSalt returns "" when the salt is long enough. Entropy cannot
// be checked on-chain; only length is enforced.
func ValidateSalt(salt string) string {
	if len(salt) < MinSaltLen {
		return "salt must be at least 16 characters"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Bounty
// ---------------------------------------------------------------------------

// Bounty is one sponsored audit with a locked pool.
// v1 pricing model (design §5.6): poolTotal is the sum of the four tier
// prices, and each tier pays at most once (first valid finding per tier).
type Bounty struct {
	id        uint64
	sponsor   address
	arbiter   address // appointed by the sponsor; may be a third party
	title     string  // <= MaxTitleLen
	scope     string  // audited realm, <= MaxScopeLen
	poolTotal int64   // ugnot locked at creation (+ top-ups)
	poolLeft  int64   // remaining payable amount
	paidOut   int64   // ugnot paid to hunters so far
	refunded  int64   // ugnot refunded to the sponsor so far
	priceCrit int64   // price per tier (ugnot)
	priceHigh int64
	priceMed  int64
	priceLow  int64
	createdAt int64 // block height
	deadline  int64 // height: no new commits after this
	status    BountyStatus
	// Outcome counters (design §4: stored as counters, not derived).
	acceptedCount  int64
	duplicateCount int64
	rejectedCount  int64
	// paidTiers is the authoritative tier-once record (design §5.6):
	// bit (sev-1) is set when that severity tier has been paid for
	// this bounty. It is the ONLY enforcement that does not depend on
	// a caller-supplied findings list — see RecordPayout and
	// TierAlreadyPaid (defence-in-depth). It survives TopUp: topping
	// up the pool never re-opens a paid tier.
	paidTiers uint8
}

// ValidateNewBounty checks constructor arguments and returns "" when
// they are all valid, otherwise a human-readable reason. NewBounty
// panics with the same reason; the realm converts it into a rejected
// transaction.
func ValidateNewBounty(sponsor, arbiter address, title, scope string, priceCrit, priceHigh, priceMed, priceLow, createdAt, deadline int64) string {
	if sponsor == "" {
		return "sponsor address must not be empty"
	}
	if arbiter == "" {
		return "arbiter address must not be empty"
	}
	if len(title) == 0 || len(title) > MaxTitleLen {
		return "title must be 1-100 characters"
	}
	if len(scope) == 0 || len(scope) > MaxScopeLen {
		return "scope must be 1-1000 characters"
	}
	for _, p := range []int64{priceCrit, priceHigh, priceMed, priceLow} {
		if p < MinTierPrice {
			return "each tier price must be at least 100000 ugnot"
		}
	}
	total, ok := CheckedAdd(priceCrit, priceHigh)
	if !ok {
		return "tier prices overflow"
	}
	total, ok = CheckedAdd(total, priceMed)
	if !ok {
		return "tier prices overflow"
	}
	total, ok = CheckedAdd(total, priceLow)
	if !ok {
		return "tier prices overflow"
	}
	if total < MinBountyReward {
		return "pool total must be at least 1000000 ugnot (1 GNOT)"
	}
	if deadline < createdAt {
		return "deadline must not be before creation height"
	}
	if createdAt < 0 {
		return "creation height must not be negative"
	}
	return ""
}

// NewBounty builds a Bounty in state Open with the full pool locked.
// It panics on invalid arguments (see ValidateNewBounty).
func NewBounty(id uint64, sponsor, arbiter address, title, scope string, priceCrit, priceHigh, priceMed, priceLow, createdAt, deadline int64) Bounty {
	if msg := ValidateNewBounty(sponsor, arbiter, title, scope, priceCrit, priceHigh, priceMed, priceLow, createdAt, deadline); msg != "" {
		panic(msg)
	}
	total, _ := CheckedAdd(priceCrit, priceHigh)
	total, _ = CheckedAdd(total, priceMed)
	total, _ = CheckedAdd(total, priceLow)
	return Bounty{
		id: id, sponsor: sponsor, arbiter: arbiter,
		title: title, scope: scope,
		poolTotal: total, poolLeft: total,
		priceCrit: priceCrit, priceHigh: priceHigh,
		priceMed: priceMed, priceLow: priceLow,
		createdAt: createdAt, deadline: deadline,
		status: BountyOpen,
	}
}

// PriceFor returns the configured price of a severity tier.
func (b Bounty) PriceFor(sev Severity) int64 {
	switch sev {
	case SevCritical:
		return b.priceCrit
	case SevHigh:
		return b.priceHigh
	case SevMedium:
		return b.priceMed
	case SevLow:
		return b.priceLow
	default:
		return 0
	}
}

// CheckInvariant verifies design §4.2 invariant 1, 5 and 6 for this
// bounty and returns "" when they hold, otherwise a reason.
func (b Bounty) CheckInvariant() string {
	if !b.status.Valid() {
		return "invalid bounty status"
	}
	if b.poolLeft < 0 || b.paidOut < 0 || b.refunded < 0 || b.poolTotal < 0 {
		return "negative pool amount"
	}
	sum, ok := CheckedAdd(b.poolLeft, b.paidOut)
	if !ok {
		return "pool accounting overflow"
	}
	sum, ok = CheckedAdd(sum, b.refunded)
	if !ok {
		return "pool accounting overflow"
	}
	if sum != b.poolTotal {
		return "poolLeft + paidOut + refunded != poolTotal"
	}
	if b.deadline < b.createdAt {
		return "deadline before creation height"
	}
	return ""
}

// TierPaid reports whether a severity tier has already been paid for
// this bounty (design §5.6). Invalid severities report unpaid.
func (b Bounty) TierPaid(sev Severity) bool {
	if !sev.Valid() {
		return false
	}
	return b.paidTiers&(uint8(1)<<(uint8(sev)-1)) != 0
}

// RecordPayout moves amount from poolLeft to paidOut and returns the
// payout the realm must execute with SendCoins. Callers must move the
// finding to a final status in the same transaction (CEI: state first,
// coins second). It panics on invalid amounts, insufficient pool, or
// a tier that has already been paid — the paidTiers flag is set here,
// at the single choke point where hunter money moves, so no verdict
// path can pay a tier twice even if the caller passes a wrong or
// empty `others` list to the verdict (see TierAlreadyPaid).
func (b *Bounty) RecordPayout(to address, sev Severity, amount int64) Payout {
	if b.status != BountyOpen {
		panic("payout only from an Open bounty")
	}
	if to == "" {
		panic("payout recipient must not be empty")
	}
	if amount <= 0 {
		panic("payout amount must be positive")
	}
	if !sev.Valid() {
		panic("payout severity must be a valid tier")
	}
	if b.TierPaid(sev) {
		panic("this severity tier has already been paid for this bounty")
	}
	if amount > b.poolLeft {
		panic("payout exceeds pool left")
	}
	b.paidTiers |= uint8(1) << (uint8(sev) - 1)
	b.poolLeft -= amount
	b.paidOut += amount
	b.acceptedCount++
	return NewPayout(PayoutPayHunter, to, amount)
}

// RecordRefund moves amount from poolLeft to refunded and returns the
// payout the realm must execute. Used by Cancel/Close. It panics on
// invalid amounts or insufficient pool.
func (b *Bounty) RecordRefund(to address, amount int64) Payout {
	if b.status != BountyOpen {
		panic("refund only from an Open bounty")
	}
	if to == "" {
		panic("refund recipient must not be empty")
	}
	if amount <= 0 {
		panic("refund amount must be positive")
	}
	if amount > b.poolLeft {
		panic("refund exceeds pool left")
	}
	b.poolLeft -= amount
	b.refunded += amount
	return NewPayout(PayoutRefundSponsor, to, amount)
}

// RecordDuplicate notes an arbiter duplicate verdict (no money moves).
func (b *Bounty) RecordDuplicate() {
	b.duplicateCount++
}

// RecordRejected notes an arbiter rejection (no money moves).
func (b *Bounty) RecordRejected() {
	b.rejectedCount++
}

// Close marks the bounty Closed (final). The realm must refund the
// remaining pool first via RecordRefund; Close panics while poolLeft > 0
// so funds can never be stranded in a Closed bounty.
func (b *Bounty) Close() {
	if b.status != BountyOpen {
		panic("only an Open bounty can close")
	}
	if b.poolLeft != 0 {
		panic("cannot close with pool left; refund first")
	}
	b.status = BountyClosed
}

// Cancel marks the bounty Cancelled (final). Same refund-first rule as Close.
func (b *Bounty) Cancel() {
	if b.status != BountyOpen {
		panic("only an Open bounty can cancel")
	}
	if b.poolLeft != 0 {
		panic("cannot cancel with pool left; refund first")
	}
	b.status = BountyCancelled
}

// Getters — all return value copies.
func (b Bounty) ID() uint64            { return b.id }
func (b Bounty) Sponsor() address      { return b.sponsor }
func (b Bounty) Arbiter() address      { return b.arbiter }
func (b Bounty) Title() string         { return b.title }
func (b Bounty) Scope() string         { return b.scope }
func (b Bounty) PoolTotal() int64      { return b.poolTotal }
func (b Bounty) PoolLeft() int64       { return b.poolLeft }
func (b Bounty) PaidOut() int64        { return b.paidOut }
func (b Bounty) Refunded() int64       { return b.refunded }
func (b Bounty) PriceCrit() int64      { return b.priceCrit }
func (b Bounty) PriceHigh() int64      { return b.priceHigh }
func (b Bounty) PriceMed() int64       { return b.priceMed }
func (b Bounty) PriceLow() int64       { return b.priceLow }
func (b Bounty) CreatedAt() int64      { return b.createdAt }
func (b Bounty) Deadline() int64       { return b.deadline }
func (b Bounty) Status() BountyStatus  { return b.status }
func (b Bounty) AcceptedCount() int64  { return b.acceptedCount }
func (b Bounty) DuplicateCount() int64 { return b.duplicateCount }
func (b Bounty) RejectedCount() int64  { return b.rejectedCount }

// ---------------------------------------------------------------------------
// Finding
// ---------------------------------------------------------------------------

// Finding is one hunter's report against a bounty.
// The salt is NEVER stored: only the hunter holds it; the realm
// recomputes the commitment from the revealed fields + salt.
type Finding struct {
	id             uint64
	bountyID       uint64
	hunter         address
	severity       Severity // hunter's claim at commit; arbiter may correct it
	severityFinal  Severity // 0 until the verdict sets the final tier
	commitHash     string   // 64 lowercase hex sha256 (see §4.1)
	committedAt    int64
	revealDeadline int64  // committedAt + RevealWindow; unrevealed commits lapse
	title          string // <= MaxTitleLen, set at reveal
	pocURL         string // <= MaxPocURLLen, https://, set at reveal
	revealedAt     int64
	reviewDeadline int64 // revealedAt + ReviewWindow; arbiter must decide by this height
	status         FindingStatus
	verdictBy      address
	verdictAt      int64
	verdictReason  string // <= MaxReasonLen
	duplicateOf    uint64 // when Duplicate: id of the original finding
	paidAmount     int64  // ugnot paid (0 when not paid)
	disclosedAt    int64
	disputed       bool   // true once the hunter has disputed a rejection
	disputeReason  string // <= MaxReasonLen, set at dispute
	disputedAt     int64  // block height of the dispute; starts the
	// arbiter -> sponsor -> hunter timeout ladder for Disputed
	// findings (see DisputeReviewDeadlineAt / DisputeClaimableAfter)
}

// ValidateNewFinding checks commit-time arguments; "" means valid.
func ValidateNewFinding(hunter address, severity Severity, commitHash string, committedAt, revealDeadline int64) string {
	if hunter == "" {
		return "hunter address must not be empty"
	}
	if !severity.Valid() {
		return "invalid severity"
	}
	if msg := ValidateCommitHash(commitHash); msg != "" {
		return msg
	}
	if revealDeadline <= committedAt {
		return "reveal deadline must be after commit height"
	}
	if committedAt < 0 {
		return "commit height must not be negative"
	}
	return ""
}

// NewFinding builds a Finding in state Committed. It panics on invalid
// arguments (see ValidateNewFinding).
func NewFinding(id, bountyID uint64, hunter address, severity Severity, commitHash string, committedAt, revealDeadline int64) Finding {
	if msg := ValidateNewFinding(hunter, severity, commitHash, committedAt, revealDeadline); msg != "" {
		panic(msg)
	}
	return Finding{
		id: id, bountyID: bountyID, hunter: hunter,
		severity: severity, commitHash: commitHash,
		committedAt: committedAt, revealDeadline: revealDeadline,
		status: FindingCommitted,
	}
}

// ValidateReveal checks reveal-time arguments; "" means valid. The
// commitment itself is verified by the realm with MakeCommitment.
func ValidateReveal(title, pocURL, salt string) string {
	if len(title) == 0 || len(title) > MaxTitleLen {
		return "title must be 1-100 characters"
	}
	if len(pocURL) == 0 || len(pocURL) > MaxPocURLLen {
		return "PoC URL must be 1-300 characters"
	}
	if !strings.HasPrefix(pocURL, "https://") {
		return "PoC URL must start with https://"
	}
	if msg := ValidateSalt(salt); msg != "" {
		return msg
	}
	return ""
}

// CheckInvariant verifies design §4.2 invariant 6 for this finding.
func (f Finding) CheckInvariant() string {
	if !f.status.Valid() {
		return "invalid finding status"
	}
	if f.revealDeadline <= f.committedAt {
		return "reveal deadline must be after commit height"
	}
	if f.severityFinal != 0 && !f.severityFinal.Valid() {
		return "invalid final severity"
	}
	if f.paidAmount < 0 {
		return "negative paid amount"
	}
	if f.reviewDeadline != 0 && f.revealedAt != 0 && f.reviewDeadline <= f.revealedAt {
		return "review deadline must be after reveal height"
	}
	switch f.status {
	case FindingRevealed, FindingDisputed, FindingAccepted, FindingDuplicate, FindingRejected, FindingDisclosed:
		if f.reviewDeadline == 0 {
			return "review deadline must be set once revealed"
		}
	}
	if f.status == FindingDisputed && !f.disputed {
		return "disputed status requires a recorded dispute"
	}
	if len(f.disputeReason) > MaxReasonLen {
		return "dispute reason too long"
	}
	return ""
}

// Getters — all return value copies.
func (f Finding) ID() uint64              { return f.id }
func (f Finding) BountyID() uint64        { return f.bountyID }
func (f Finding) Hunter() address         { return f.hunter }
func (f Finding) Severity() Severity      { return f.severity }
func (f Finding) SeverityFinal() Severity { return f.severityFinal }
func (f Finding) CommitHash() string      { return f.commitHash }
func (f Finding) CommittedAt() int64      { return f.committedAt }
func (f Finding) RevealDeadline() int64   { return f.revealDeadline }
func (f Finding) Title() string           { return f.title }
func (f Finding) PocURL() string          { return f.pocURL }
func (f Finding) RevealedAt() int64       { return f.revealedAt }
func (f Finding) ReviewDeadline() int64   { return f.reviewDeadline }
func (f Finding) Status() FindingStatus   { return f.status }
func (f Finding) VerdictBy() address      { return f.verdictBy }
func (f Finding) VerdictAt() int64        { return f.verdictAt }
func (f Finding) VerdictReason() string   { return f.verdictReason }
func (f Finding) DuplicateOf() uint64     { return f.duplicateOf }
func (f Finding) PaidAmount() int64       { return f.paidAmount }
func (f Finding) DisclosedAt() int64      { return f.disclosedAt }
func (f Finding) DisputedBefore() bool    { return f.disputed }
func (f Finding) DisputeReason() string   { return f.disputeReason }
func (f Finding) DisputedAt() int64       { return f.disputedAt }

// ---------------------------------------------------------------------------
// HunterStats
// ---------------------------------------------------------------------------

// HunterStats is the public reputation record of one hunter.
// Ranking: accepted desc, earned desc, address asc (deterministic).
type HunterStats struct {
	addr       address
	submitted  int
	accepted   int
	duplicates int
	rejected   int
	earned     int64 // total ugnot received
}

// NewHunterStats builds an empty record for addr. It panics on an empty address.
func NewHunterStats(addr address) HunterStats {
	if addr == "" {
		panic("hunter address must not be empty")
	}
	return HunterStats{addr: addr}
}

// RecordSubmitted counts one new finding (any status).
func (s *HunterStats) RecordSubmitted() { s.submitted++ }

// RecordAccepted counts one paid finding and adds its payout to earned.
func (s *HunterStats) RecordAccepted(amount int64) {
	if amount < 0 {
		panic("accepted amount must not be negative")
	}
	total, ok := CheckedAdd(s.earned, amount)
	if !ok {
		panic("hunter earned overflow")
	}
	s.earned = total
	s.accepted++
}

// RecordDuplicate counts one finding marked duplicate.
func (s *HunterStats) RecordDuplicate() { s.duplicates++ }

// RecordRejected counts one rejected finding.
func (s *HunterStats) RecordRejected() { s.rejected++ }

// Getters.
func (s HunterStats) Addr() address   { return s.addr }
func (s HunterStats) Submitted() int  { return s.submitted }
func (s HunterStats) Accepted() int   { return s.accepted }
func (s HunterStats) Duplicates() int { return s.duplicates }
func (s HunterStats) Rejected() int   { return s.rejected }
func (s HunterStats) Earned() int64   { return s.earned }

// ---------------------------------------------------------------------------
// ArbiterStats
// ---------------------------------------------------------------------------

// ArbiterStats is the public track record of one arbiter.
type ArbiterStats struct {
	addr       address
	verdicts   int
	accepted   int
	rejected   int
	duplicates int
	timeouts   int // times the arbiter's verdict right expired
}

// NewArbiterStats builds an empty record for addr. It panics on an empty address.
func NewArbiterStats(addr address) ArbiterStats {
	if addr == "" {
		panic("arbiter address must not be empty")
	}
	return ArbiterStats{addr: addr}
}

// RecordVerdict counts one verdict of the given outcome.
func (s *ArbiterStats) RecordVerdict(accepted, rejected, duplicate bool) {
	s.verdicts++
	switch {
	case accepted:
		s.accepted++
	case rejected:
		s.rejected++
	case duplicate:
		s.duplicates++
	}
}

// RecordTimeout counts one expired verdict right (arbiter stayed silent).
func (s *ArbiterStats) RecordTimeout() { s.timeouts++ }

// Getters.
func (s ArbiterStats) Addr() address   { return s.addr }
func (s ArbiterStats) Verdicts() int   { return s.verdicts }
func (s ArbiterStats) Accepted() int   { return s.accepted }
func (s ArbiterStats) Rejected() int   { return s.rejected }
func (s ArbiterStats) Duplicates() int { return s.duplicates }
func (s ArbiterStats) Timeouts() int   { return s.timeouts }

// ---------------------------------------------------------------------------
// Payout
// ---------------------------------------------------------------------------

// PayoutKind says what a payout is for.
type PayoutKind uint8

const (
	// PayoutNone is the zero value: no payout is due.
	PayoutNone PayoutKind = iota
	// PayoutPayHunter pays a hunter for an accepted finding.
	PayoutPayHunter
	// PayoutRefundSponsor refunds remaining pool to the sponsor.
	PayoutRefundSponsor
)

// Payout is the single coin movement a state transition may cause.
// Guarantee (design §4): a non-zero payout is only ever returned
// together with a move to a final state, and final states refuse all
// moves — so one finding can pay out at most once.
type Payout struct {
	Kind   PayoutKind
	To     address
	Amount int64
}

// NewPayout builds a payout. It panics on an empty recipient, a
// non-positive amount, or PayoutNone with an amount.
func NewPayout(kind PayoutKind, to address, amount int64) Payout {
	if kind == PayoutNone {
		panic("payout kind must not be None")
	}
	if to == "" {
		panic("payout recipient must not be empty")
	}
	if amount <= 0 {
		panic("payout amount must be positive")
	}
	return Payout{Kind: kind, To: to, Amount: amount}
}

// Due reports whether this payout must be executed (design §4): a
// kind is set AND the amount is positive, so a hand-built struct
// literal with a kind and a zero amount is never treated as due.
func (p Payout) Due() bool { return p.Kind != PayoutNone && p.Amount > 0 }
