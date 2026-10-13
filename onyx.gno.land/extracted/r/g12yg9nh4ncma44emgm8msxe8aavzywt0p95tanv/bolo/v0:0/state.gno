package bolo

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// Params are the settings snapshotted into each campaign when it is created
// (API §2.2): its deposit and its timers never change afterwards (INV-5).
// Durations are in seconds.
type Params struct {
	CreationDeposit int64
	DormancyPeriod  int64
	ExitDelay       int64
	BondHold        int64
}

// Custody modes, statuses and close reasons (API §2.1).
const (
	modeDirect = "direct"
	modeEscrow = "escrow"

	statusOpen    = "open"
	statusClosed  = "closed"
	statusSettled = "settled"

	reasonOrganizer = "organizer"
	reasonDeadline  = "deadline"
	reasonDormant   = "dormant"
)

// campaign holds what never changes once a campaign is created (INV-10), and
// points to what does. Gno re-saves a changed object and every object that owns
// it, up to the first with two owners, so each donation re-saves this object with
// its hot state and its trees: it holds only small fields, and the organizer's
// text lives in its own object, written once (API §2.5).
type campaign struct {
	id          seqid.ID
	category    string
	organizer   address
	beneficiary address
	mode        string // modeDirect or modeEscrow
	goal        int64  // ugnot; 0: no goal
	deadline    int64  // Unix seconds; 0: none
	createdAt   int64
	params      Params

	text  *campaignText  // written once; read by views and Render
	state *campaignState // counters, timers and flags

	// One object each, keyed by donor address or by seqid.Binary(): a donation
	// writes O(log n) small nodes, not the campaign's history.
	contributions *avl.Tree // address → *contribution
	receipts      *avl.Tree // seq → *receipt
	withdrawals   *avl.Tree // seq → *withdrawal
	refunds       *avl.Tree // seq → *refund
	updates       *avl.Tree // seq → *update
}

// campaignText is what the organizer wrote, which never changes (INV-10): written
// once, off the path every donation re-saves.
type campaignText struct {
	title       string
	description string
	imageCID    string
	imageAlt    string
}

const recentSize = 20

// campaignState is a campaign's hot object: small, rewritten on every donation.
type campaignState struct {
	status      string // as stored; a passed deadline counts as closed before it is recorded
	closeReason string
	closedAt    int64
	listed      bool
	notice      string
	imageHidden bool

	raised    int64 // gross: every donation ever
	refunded  int64
	withdrawn int64 // tracked coins only; untracked ones are counted apart

	donorCount    int
	donationCount int
	refundCount   int
	updateCount   int

	bond         int64
	bondSlashed  bool
	bondReleased bool

	lastDonationAt int64
	lastUpdateAt   int64
	everWithdrawn  bool // ends the open refund window for good

	// The exit window's snapshot, frozen by the first exit claim (API §3.2).
	exitFrozen bool
	exitPool   int64
	exitBase   int64

	// The last donations' sequence numbers, a ring: numbers, not receipts.
	recent     [recentSize]uint64
	recentNext int

	receiptSeq    seqid.ID
	withdrawalSeq seqid.ID
	refundSeq     seqid.ID
	updateSeq     seqid.ID
}

// contribution is one donor's record in one campaign (API §3.2).
type contribution struct {
	amount      int64 // everything given
	refunded    int64 // everything paid back
	exitClaimed bool  // the one exit claim is used (INV-17)
	public      bool  // at least one gift wasn't anonymous
}

// receipt is one donation.
type receipt struct {
	seq           uint64
	donor         address
	anonymous     bool
	amount        int64
	tip           int64
	message       string
	messageHidden bool
	at            int64
	raisedAfter   int64

	refundedBefore int64 // what this donor was refunded on this campaign before this gift
}

// withdrawal is one payout to the beneficiary.
type withdrawal struct {
	seq       uint64
	amount    int64 // tracked coins
	untracked int64 // coins sent to the escrow outside Bolo
	at        int64
	to        address
}

// refund is one payout to a donor.
type refund struct {
	seq    uint64
	amount int64
	at     int64
	donor  address
	kind   string // "open" or "exit"
}

// update is one organizer update: append-only.
type update struct {
	seq  uint64
	at   int64
	body string
}

// Package state, all unexported (API C6).
var (
	nextID    seqid.ID // the last campaign ID given out
	campaigns avl.Tree // seqid.Binary() → *campaign

	// derived holds every escrow and bond address a campaign ever got: none of
	// them may be a beneficiary (API §1).
	derived avl.Tree // address → true

	// The indexes (API §2.5): keys sort newest campaign last.
	active           avl.Tree // seqid.Binary() → true: the open, listed campaigns
	activeByCategory avl.Tree // category + "/" + seqid.Binary() → true: the same
	byOrganizer      avl.Tree // organizer + "/" + seqid.Binary() → true
	byBeneficiary    avl.Tree // beneficiary + "/" + seqid.Binary() → true
	byDonor          avl.Tree // donor + "/" + seqid.Binary() → true: a gift that wasn't anonymous
)
