// Package sealed runs token launches as sealed-bid, uniform-price auctions.
//
// On-chain launches reward speed: bots buy first and humans lose. SEALED
// removes the edge:
//
//  1. COMMIT  - a buyer posts only sha256(bidder|price|amount|salt) plus a
//     GNOT deposit. Nobody can read any bid.
//  2. REVEAL  - the buyer opens the bid. The realm re-hashes it and checks
//     the commitment and that the deposit covers price*amount.
//  3. SETTLE  - anyone can trigger it. Bids fill from the highest price
//     down until supply runs out, and EVERY winner pays the same clearing
//     price (the lowest filled bid). Ties at the clearing price split
//     pro-rata: there is no time priority anywhere.
//
// Money only moves through Claim (pull pattern): each bidder withdraws their
// own tokens and refund, and the seller withdraws proceeds and unsold
// tokens. Nothing loops over bidders to pay them.
//
// Units: `supply` and `amount` are token base units. `price` and
// `reservePrice` are ugnot (1 GNOT = 1,000,000 ugnot) per token base unit.
// Times are Unix seconds, compared against block time.
package sealed

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"math/overflow"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	// Denom is the only coin accepted as a deposit.
	Denom = "ugnot"

	// ForfeitPercent of the deposit is kept from a bidder who commits but
	// never reveals (anti-spam). It is shared by the winners in proportion
	// to tokens won, and burned if nobody won. It never goes to the seller,
	// so a seller gains nothing from fake bids that never reveal.
	ForfeitPercent = 10

	// MinDeposit stops dust commitments from filling an auction's bid slots.
	MinDeposit int64 = 100_000 // 0.1 GNOT

	// MaxBidsPerAuction bounds the work Settle does.
	MaxBidsPerAuction = 200

	// Salt limits. Price and amount are easy to guess, so the salt is what
	// keeps a commitment from being brute-forced during the commit phase.
	MinSaltLen = 8
	MaxSaltLen = 128

	// MaxPhaseDuration caps each phase so funds can't be locked for years.
	MaxPhaseDuration int64 = 30 * 24 * 60 * 60
)

// Phase is where an auction is in its life cycle.
type Phase int

const (
	PhaseCommit  Phase = iota // sealed bids are accepted
	PhaseReveal               // bids are opened
	PhaseClosed               // reveal window over, waiting for Settle
	PhaseSettled              // results final, claims open
)

func (p Phase) String() string {
	switch p {
	case PhaseCommit:
		return "Commit"
	case PhaseReveal:
		return "Reveal"
	case PhaseClosed:
		return "Ready to settle"
	case PhaseSettled:
		return "Settled"
	}
	return "Unknown"
}

// Bid is one address's sealed bid in one auction.
type Bid struct {
	Bidder     address
	Commitment string // lowercase hex sha256
	Deposit    int64  // ugnot
	Revealed   bool
	Price      int64 // ugnot per token unit, set on reveal
	Amount     int64 // token units wanted, set on reveal
	Claimed    bool
}

// Auction is one sealed-bid launch.
type Auction struct {
	ID           seqid.ID
	Seller       address
	Token        string // grc20reg key, e.g. "gno.land/r/g15xk7p2u3q6epjq5kfyew2lku5epakfnat7fj40/tavern/v1.TAVERN"
	Supply       int64  // token units escrowed by the seller
	ReservePrice int64  // ugnot per token unit; lower bids never fill
	CommitEnd    int64  // unix seconds
	RevealEnd    int64  // unix seconds
	CreatedAt    int64  // unix seconds

	bids          *avl.Tree // bidder address -> *Bid
	numRevealed   int
	totalDeposits int64

	// Settlement results. Each bid's fill is derived from these, so Settle
	// never writes to individual bids.
	settled       bool
	clearingPrice int64 // lowest filled price; 0 if nothing sold
	sold          int64 // token units sold
	raised        int64 // clearingPrice * sold
	forfeits      int64 // ugnot kept from bids that were never revealed
	burned        int64 // part of forfeits nobody can claim (no winners, or rounding)
	hasFullFill   bool
	fullFillMin   int64 // valid bids priced >= this fill completely
	partialPrice  int64 // the price level that was split pro-rata
	partialSupply int64 // supply left for that level
	partialDemand int64 // total amount wanted at that level (0 = no split)
	sellerClaimed bool
}

var (
	auctions = avl.NewTree() // seqid binary key -> *Auction
	nextID   seqid.ID

	realmPath string  // this realm's package path, set in init
	realmAddr address // this realm's address: sellers approve it
)

func init(cur realm) {
	realmPath = cur.PkgPath()
	realmAddr = cur.Address()
}

// Address returns the realm address. A seller must approve it on the token
// for at least `supply` before calling CreateAuction.
func Address() address { return realmAddr }

// ---------------------------------------------------------------------------
// Commitments

// MakeCommitment returns hex(sha256(bidder|price|amount|salt)), the value a
// bidder passes to Commit. Compute it locally (see scripts/commitment.sh):
// asking a public node to evaluate it would show your bid to that node.
func MakeCommitment(bidder address, price, amount int64, salt string) string {
	msg := bidder.String() + "|" + strconv.FormatInt(price, 10) + "|" +
		strconv.FormatInt(amount, 10) + "|" + salt
	sum := sha256.Sum256([]byte(msg))
	return hex.EncodeToString(sum[:])
}

func normalizeCommitment(c string) string {
	c = strings.ToLower(strings.TrimSpace(c))
	if len(c) != 64 {
		panic("sealed: commitment must be 64 hex characters (a sha256 digest)")
	}
	for _, r := range c {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			panic("sealed: commitment must be hex")
		}
	}
	return c
}

// ---------------------------------------------------------------------------
// Public entry points

// CreateAuction escrows `supply` units of a GRC20 token and opens a
// sealed-bid auction. `token` is the token's grc20reg key. The caller must
// first approve Address() on the token for at least `supply`.
// `commitEnd` and `revealEnd` are Unix timestamps (seconds).
func CreateAuction(cur realm, token string, supply, reservePrice, commitEnd, revealEnd int64) uint64 {
	seller := cur.Previous().Address()
	now := time.Now().Unix()

	tok := grc20reg.Get(token)
	if tok == nil {
		panic("sealed: unknown token " + strconv.Quote(token) + " (use its grc20reg key, like gno.land/r/g15xk7p2u3q6epjq5kfyew2lku5epakfnat7fj40/tavern/v1.TAVERN)")
	}
	if supply <= 0 {
		panic("sealed: supply must be positive")
	}
	if reservePrice < 0 {
		panic("sealed: reserve price cannot be negative")
	}
	if commitEnd <= now {
		panic("sealed: commitEnd must be in the future (unix seconds)")
	}
	if revealEnd <= commitEnd {
		panic("sealed: revealEnd must be after commitEnd")
	}
	if commitEnd-now > MaxPhaseDuration || revealEnd-commitEnd > MaxPhaseDuration {
		panic("sealed: each phase can last at most 30 days")
	}
	if allowed := tok.Allowance(seller, realmAddr); allowed < supply {
		panic("sealed: approve " + realmAddr.String() + " on the token for at least " +
			strconv.FormatInt(supply, 10) + " first (current allowance " +
			strconv.FormatInt(allowed, 10) + ")")
	}

	// Escrow the sale tokens: seller -> this realm.
	grc20reg.TransferFrom(0, cur, token, seller, realmAddr, supply)

	id := nextID.Next()
	a := &Auction{
		ID:           id,
		Seller:       seller,
		Token:        token,
		Supply:       supply,
		ReservePrice: reservePrice,
		CommitEnd:    commitEnd,
		RevealEnd:    revealEnd,
		CreatedAt:    now,
		bids:         avl.NewTree(),
	}
	auctions.Set(id.Binary(), a)

	chain.Emit("AuctionCreated",
		"id", strconv.FormatUint(uint64(id), 10),
		"seller", seller.String(),
		"token", token,
		"supply", strconv.FormatInt(supply, 10),
		"reservePrice", strconv.FormatInt(reservePrice, 10),
		"commitEnd", strconv.FormatInt(commitEnd, 10),
		"revealEnd", strconv.FormatInt(revealEnd, 10),
	)
	return uint64(id)
}

// Commit places a sealed bid. Send the GNOT deposit with the call
// (gnokey -send). The deposit must cover price*amount; depositing more
// hides your real bid size and the extra is refunded at Claim.
// One commitment per address per auction.
func Commit(cur realm, auctionID uint64, commitment string) {
	prev := cur.Previous()
	// The deposit is read from the transaction's coin envelope, so only a
	// direct user call (gnokey maketx call) may commit: an intermediate
	// realm or a maketx run script could otherwise reuse that envelope.
	if !prev.IsUserCall() {
		panic("sealed: Commit must be called directly from a user account")
	}
	bidder := prev.Address()
	a := mustGetAuction(auctionID)
	if a.phaseAt(time.Now().Unix()) != PhaseCommit {
		panic("sealed: the commit phase is over")
	}
	commitment = normalizeCommitment(commitment)
	if a.bids.Has(bidder.String()) {
		panic("sealed: this address already committed to this auction (one sealed bid per address)")
	}
	if a.bids.Size() >= MaxBidsPerAuction {
		panic("sealed: this auction is full")
	}
	deposit := depositFromSend()
	if deposit < MinDeposit {
		panic("sealed: deposit must be at least " + strconv.FormatInt(MinDeposit, 10) + "ugnot")
	}
	total, ok := overflow.Add64(a.totalDeposits, deposit)
	if !ok {
		panic("sealed: deposit overflow")
	}
	a.totalDeposits = total
	a.bids.Set(bidder.String(), &Bid{
		Bidder:     bidder,
		Commitment: commitment,
		Deposit:    deposit,
	})

	chain.Emit("BidSealed",
		"id", idStr(a),
		"bidder", bidder.String(),
		"sealedBids", strconv.Itoa(a.bids.Size()),
	)
}

// Reveal opens the caller's sealed bid. It is accepted only if
// sha256(bidder|price|amount|salt) matches the commitment and the deposit
// covers price*amount.
func Reveal(cur realm, auctionID uint64, price, amount int64, salt string) {
	bidder := cur.Previous().Address()
	a := mustGetAuction(auctionID)
	switch a.phaseAt(time.Now().Unix()) {
	case PhaseCommit:
		panic("sealed: too early to reveal, the commit phase is still open")
	case PhaseReveal:
	default:
		panic("sealed: the reveal window has closed")
	}
	b := a.getBid(bidder)
	if b == nil {
		panic("sealed: no sealed bid from this address")
	}
	if b.Revealed {
		panic("sealed: bid already revealed")
	}
	if price <= 0 || amount <= 0 {
		panic("sealed: price and amount must be positive")
	}
	if len(salt) < MinSaltLen || len(salt) > MaxSaltLen {
		panic("sealed: salt must be 8 to 128 characters")
	}
	if MakeCommitment(bidder, price, amount, salt) != b.Commitment {
		panic("sealed: reveal does not match the commitment (check price, amount and salt)")
	}
	cost, ok := overflow.Mul64(price, amount)
	if !ok || cost > b.Deposit {
		panic("sealed: insufficient deposit: the bid needs " + formatGNOT(cost) +
			" but only " + formatGNOT(b.Deposit) + " was deposited")
	}
	b.Revealed = true
	b.Price = price
	b.Amount = amount
	a.numRevealed++

	chain.Emit("BidRevealed",
		"id", idStr(a),
		"bidder", bidder.String(),
		"price", strconv.FormatInt(price, 10),
		"amount", strconv.FormatInt(amount, 10),
	)
}

// Settle computes the clearing price and every allocation. Anyone can call
// it once the reveal window has closed. It moves no funds.
func Settle(cur realm, auctionID uint64) {
	a := mustGetAuction(auctionID)
	a.settle(time.Now().Unix())
	emitSettled(a)
}

// Claim pays out whatever the caller is owed by a settled auction (it
// settles first if needed):
//   - a bidder gets their tokens won plus their GNOT refund
//     (deposit - tokens*clearingPrice, or 90% of it if they never revealed),
//     plus, for a winner, a share of the no-show forfeits;
//   - the seller gets the proceeds (tokens sold x clearing price) and the
//     unsold tokens. Never any forfeit.
func Claim(cur realm, auctionID uint64) {
	caller := cur.Previous().Address()
	a := mustGetAuction(auctionID)
	if !a.settled {
		a.settle(time.Now().Unix())
		emitSettled(a)
	}

	var gnotOut, tokensOut int64
	claimed := false
	if caller == a.Seller && !a.sellerClaimed {
		a.sellerClaimed = true
		gnotOut += a.raised
		tokensOut += a.Supply - a.sold
		claimed = true
	}
	if b := a.getBid(caller); b != nil && !b.Claimed {
		b.Claimed = true
		o := a.outcomeOf(b)
		gnotOut += o.Payout()
		tokensOut += o.Filled
		claimed = true
	}
	if !claimed {
		panic("sealed: nothing to claim for this address")
	}

	// State is final before any funds move.
	if tokensOut > 0 {
		grc20reg.Transfer(0, cur, a.Token, caller, tokensOut)
	}
	if gnotOut > 0 {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(realmAddr, caller, chain.Coins{{Denom, gnotOut}})
	}

	chain.Emit("Claimed",
		"id", idStr(a),
		"account", caller.String(),
		"tokens", strconv.FormatInt(tokensOut, 10),
		"ugnot", strconv.FormatInt(gnotOut, 10),
	)
}

// ---------------------------------------------------------------------------
// Read-only helpers (usable with vm/qeval)

// PhaseOf returns the auction's current phase name.
func PhaseOf(auctionID uint64) string {
	return mustGetAuction(auctionID).phaseAt(time.Now().Unix()).String()
}

// SealedBids returns how many sealed bids an auction holds.
func SealedBids(auctionID uint64) int {
	return mustGetAuction(auctionID).bids.Size()
}

// ClearingPrice returns the settled clearing price (0 before settlement).
func ClearingPrice(auctionID uint64) int64 {
	return mustGetAuction(auctionID).clearingPrice
}

// ---------------------------------------------------------------------------
// Internals

func mustGetAuction(id uint64) *Auction {
	v := auctions.Get(seqid.ID(id).Binary())
	if v == nil {
		panic("sealed: auction " + strconv.FormatUint(id, 10) + " not found")
	}
	return v.(*Auction)
}

func (a *Auction) getBid(bidder address) *Bid {
	v := a.bids.Get(bidder.String())
	if v == nil {
		return nil
	}
	return v.(*Bid)
}

func (a *Auction) phaseAt(now int64) Phase {
	switch {
	case a.settled:
		return PhaseSettled
	case now < a.CommitEnd:
		return PhaseCommit
	case now < a.RevealEnd:
		return PhaseReveal
	default:
		return PhaseClosed
	}
}

// depositFromSend reads the ugnot attached to this call. Any other coin is
// refused (the tx then reverts, so nothing gets stuck).
func depositFromSend() int64 {
	var total int64
	for _, c := range unsafe.OriginSend() {
		if c.Denom != Denom {
			panic("sealed: deposits are in ugnot only")
		}
		t, ok := overflow.Add64(total, c.Amount)
		if !ok {
			panic("sealed: deposit overflow")
		}
		total = t
	}
	return total
}

func emitSettled(a *Auction) {
	chain.Emit("AuctionSettled",
		"id", idStr(a),
		"clearingPrice", strconv.FormatInt(a.clearingPrice, 10),
		"sold", strconv.FormatInt(a.sold, 10),
		"raised", strconv.FormatInt(a.raised, 10),
		"forfeits", strconv.FormatInt(a.forfeits, 10),
		"burned", strconv.FormatInt(a.burned, 10),
	)
}
