// Realm sealedbid is a SEALED-BID SECOND-PRICE (Vickrey) auction settled in
// ugnot, holding real coins. A SELLER lists a lot; BIDDERS commit to a price
// they never disclose, by publishing only sha256(amount, salt) and escrowing a
// deposit; after the commit window closes they OPEN their bids by revealing
// (amount, salt); the highest revealed bid wins and the winner pays the SECOND
// highest price, their deposit refunded down to it.
//
// It is a different clearing rule and a different threat model from this
// portfolio's other market realm. r/auction is ascending English open-outcry:
// every bid is public the instant it lands, bidders react to each other, and
// the winner pays their own bid. Here no bidder learns another's number until
// the commit window has shut, so there is nothing to react to and nothing to
// front-run; and because the winner pays the runner-up's price, bidding one's
// true valuation is the dominant strategy rather than a mistake. The two
// realms answer the same question — who gets the lot, at what price — by
// mechanisms that do not resemble each other.
//
// COMMIT-REVEAL is the mechanism this portfolio did not have. Nothing in it
// hashed anything, on any of the three trees, before this realm.
//
// # Custody — the conservation invariant is the product
//
// A custodial realm, so the monetary invariant governs it as it does r/loans,
// r/auction and r/deposits:
//
//	Held == sealed + revealed + feeledger.Liabilities()
//
// where `sealed` is the sum of deposits behind commitments that have NOT been
// opened in a non-terminal sale, `revealed` the sum of deposits behind
// commitments that HAVE been opened and are awaiting close, and the ledger
// holds every claimable kind — losing-bid refunds, the winner's change, seller
// proceeds — plus the fee pot. The two held buckets are disjoint by
// construction: opening a bid moves its deposit from the first to the second,
// never duplicating it, and Close drains both into the ledger. Every value
// transition preserves the equality; see the DELTA-form conservation test.
//
// CORRECTION, recorded rather than shipped silently: the §7 discovery gate for
// this realm predicted THREE disjoint held buckets, naming `forfeited` as the
// third. Architecture refuted that. A forfeited deposit is credited to the
// seller at Close in the same transaction that voids the commitment, so it is
// never held as a distinct balance across any two transactions — there is no
// third bucket to be disjoint from. `forfeited` survives as a CUMULATIVE
// STATISTIC ([ForfeitedOf], [ForfeitedTotal]), which is a report and not a
// custody claim. The gate's file is not edited; this is the amendment.
//
// Payouts are PULL, never push. Close credits balances and sends nothing, so a
// hostile or contract-dead loser cannot make Close fail for everyone else, and
// the settlement path has no cross-call reentrancy surface.
//
// # Non-revelation, and why withholding never pays
//
// A sealed-bid auction has a liveness problem an ascending one does not: a
// bidder who dislikes the outcome can simply never open their bid, stalling
// settlement or distorting the price. The answer here is adopted by citation
// rather than invented — r/moul/agents/bubblerumble6 reached it independently,
// and its policy is the right one: a commitment not opened in its window is
// VOID, nothing is refunded, and the deposit is credited to the seller. So
// withholding a reveal costs the withholder their whole deposit and pays them
// nothing, and the auction always closes: Close is permissionless and needs no
// bidder to act.
//
// Two consequences of that policy are hazards, stated rather than discovered:
//
//   - A SHORT REVEAL WINDOW IS A SELLER'S INCENTIVE TO SET. The seller keeps
//     every unopened deposit, so a seller who picks the MinRevealBlocks floor
//     profits from bidders who cannot act in time. The window is public before
//     anyone commits and is reported by [SaleInfo] and [Phase]; a bidder who
//     does not like it should not commit. The realm does not second-guess a
//     disclosed term.
//   - A COMMITMENT ABOVE ONE'S DEPOSIT CAN NEVER BE OPENED. Reveal requires
//     `amount <= deposit`, so a bidder who commits to more than they escrowed
//     has no valid opening and forfeits. That is the deposit-as-ceiling rule,
//     and it is what makes the escrow sufficient: commit to no more than you
//     put up.
//
// # Privacy — what is hidden, and what is not
//
// The BID AMOUNT is hidden until the bidder opens it. The DEPOSIT is not: it
// is a coin transfer and is public, and since a valid bid cannot exceed its
// deposit, the deposit leaks an UPPER BOUND on the bid. A bidder who wants
// more privacy than that over-deposits and takes the change back at Close.
// This is the real ceiling of the scheme and is stated here because no amount
// of hashing moves it.
//
// The salt is what keeps the commitment from being brute-forced over the
// plausible round numbers, so [MinSaltLen] bytes are required. The realm can
// check a salt's LENGTH and can never check its ENTROPY: a 16-byte salt of
// "aaaaaaaaaaaaaaaa" satisfies the guard and protects nothing. Use random
// bytes. Compute the commitment locally, or with a READ-ONLY query against
// [CommitHash] — never in a transaction, which would publish the salt and
// defeat the whole mechanism.
//
// # What the realm settles, and what it does NOT
//
// The realm settles PAYMENT and records the WINNER; it does not custody or
// deliver the lot, which is free text and changes hands off-chain (or by a
// downstream realm reading [Winner]). The same scope decision r/auction states,
// for the same reason: an on-chain-asset auction is a v2 and this v1 omits the
// asset-escrow surface deliberately.
//
// REALM-CALLER CAVEAT, inherited from the siblings: coinio's receipt guard
// admits only EOA payers, so every BIDDER is an EOA. The SELLER is whoever
// calls [CreateSale]; a realm may sell, but a realm seller must expose its own
// crossing path to [Claim] or its proceeds strand — the seller's concern, not a
// third-party hazard. assertNoSend reads the ORIGIN envelope, so every
// non-payable function refuses a transaction that attached coins anywhere.
//
// # Why crypto/sha256 directly
//
// The discovery gate found genuine prior art for the hashing scheme —
// p/moul/agents/commit/v0, whose Hash is LENGTH-PREFIXED so that
// Hash("ab","c") differs from Hash("a","bc") — and deferred the import-or-
// reimplement choice to architecture. It is resolved here in favour of calling
// crypto/sha256 directly and FOLLOWING that package's scheme, because the
// package resolves to a DIFFERENT IMPORT PATH on each chain this portfolio
// targets, and the namespace rewriter substitutes only our own address. An
// import of it would make the mainnet twin of this realm non-substitutable,
// which is a structural cost that 1.4 KB of saved code does not buy.
package sealedbid

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%. The fee applies only
// to the seller's PROCEEDS at close — never to a refund, never to the winner's
// change, and never to a forfeited deposit (see Close).
const MaxFeeBps = int64(1000)

// Sale status values. Only Open is non-terminal; the phase inside Open is
// derived from the chain height, never stored.
const (
	SaleOpen      = "open"      // in its commit, reveal, or awaiting-close phase
	SaleSettled   = "settled"   // closed WITH a winner; proceeds credited
	SaleUnsold    = "unsold"    // closed with no valid opening, or below reserve
	SaleCancelled = "cancelled" // seller cancelled before any commitment
)

// Phase values returned by [Phase] for a sale that is still Open.
const (
	PhaseCommit    = "commit"    // accepting commitments
	PhaseReveal    = "reveal"    // accepting openings
	PhaseCloseable = "closeable" // reveal window shut; Close will succeed
)

// Input bounds.
const (
	// MinBid is the dust floor for any revealed bid, any deposit and any
	// non-zero reserve; MaxBid keeps every bid and the fee split far from
	// int64 overflow. The bidder must ESCROW at least their bid, so the real
	// ceiling is their balance.
	MinBid = int64(1_000)
	MaxBid = int64(1_000_000_000_000) // 1,000,000 GNOT

	// Window bounds, in blocks. The reveal floor is higher than the commit
	// floor on purpose: failing to commit costs nothing, while failing to
	// reveal costs the whole deposit, so the window in which that can happen
	// gets the wider floor. See the short-reveal-window hazard above.
	MinCommitBlocks = int64(10)
	MinRevealBlocks = int64(20)
	MaxWindowBlocks = int64(7_500_000)

	// CommitmentLen is the length of a commitment string: sha256 as 64
	// lowercase hex characters, exactly as [CommitHash] emits it.
	CommitmentLen = 2 * sha256.Size

	// MinSaltLen is the required salt length. It bounds brute force over
	// plausible bid amounts; it cannot bound a caller's choice of entropy.
	MinSaltLen = 16
	MaxSaltLen = 128

	// MaxLotLen bounds the stored lot description.
	MaxLotLen = 200

	// MaxBiddersPerSale bounds the commitments on one sale. It is the reason
	// the duplicate-commitment scan and the Close payout loop may be linear:
	// both are O(MaxBiddersPerSale) and neither is caller-extensible.
	//
	// It is ALSO a scarce resource, which is why a sale carries minDeposit.
	// A slot is never released — there is no withdraw-commitment path — so
	// without a seller-sized entry price, 25 addresses committing MinBid
	// each fill a sale for 25,000ugnot, reveal MinBid, and are refunded in
	// full fee-free: an honest bidder is locked out for the cost of gas.
	// Audit Y1, and the reason minDeposit exists. See [CreateSale].
	MaxBiddersPerSale = 25

	// MaxSalesPerSeller bounds one seller's stored sales; terminal sales do
	// NOT free the slot, because a settled/unsold/cancelled sale is a
	// permanent record a bidder and an auditor may need to read.
	MaxSalesPerSeller = 50

	// RenderLimit bounds every rendered list — an unbounded Render was YELLOW
	// in three prior audits.
	RenderLimit = 20
)

// bid is one bidder's sealed commitment and, once opened, its contents.
type bid struct {
	bidder     address
	commitment string // 64 lowercase hex chars
	deposit    int64  // escrowed at Commit; the ceiling on a valid amount
	opened     bool   // true once Reveal matched the commitment
	amount     int64  // meaningful only when opened
	revealSeq  int64  // 1-based order of opening within the sale; 0 if unopened
}

type sale struct {
	id            int64
	seller        address
	lot           string // free-text description of the lot (delivery is off-chain)
	reserve       int64  // 0 (none) or a floor the HIGHEST revealed bid must meet
	minDeposit    int64  // entry price per commitment; >= max(MinBid, reserve)
	feeBps        int64  // snapshot at create; applied to the seller's proceeds
	commitEnd     int64  // commitments accepted while height < commitEnd
	revealEnd     int64  // openings accepted while commitEnd <= height < revealEnd
	status        string
	createdHeight int64
	bids          []*bid
	revealCount   int64 // openings so far; also the revealSeq allocator

	// Settlement results, written once at Close.
	winner    address
	price     int64
	forfeited int64 // cumulative statistic, not a held bucket — see the package doc
}

var (
	admin        address
	pendingAdmin address
	feeRecipient address
	feeBps       int64 // snapshotted into NEW sales

	self   address
	nextID int64

	// The two held buckets. Disjoint by construction: Reveal moves a deposit
	// from the first to the second, and Close drains both into the ledger.
	sealed   int64 // Σ deposits behind UNOPENED commitments in non-terminal sales
	revealed int64 // Σ deposits behind OPENED commitments awaiting close

	forfeitedTotal int64 // cumulative statistic across all sales

	sales     = avl.NewTree() // padID(id)       -> *sale
	sellerNum = avl.NewTree() // seller.String() -> *int64, stored sales
	ledger    = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// --- the commitment scheme ---

// CommitHash returns the commitment for a bid of `amount` under `salt`: the
// sha256 of a LENGTH-PREFIXED encoding of the two parts, as 64 lowercase hex
// characters. The length prefixes are what make the encoding unambiguous —
// without them a commitment to (12, "34salt...") and one to (1, "234salt...")
// could collide, and a bidder could open a commitment as a bid they never
// made. The scheme follows p/moul/agents/commit/v0; see the package doc for
// why it is reimplemented rather than imported.
//
// This is a VIEW. Compute your commitment locally or with a read-only query —
// calling it inside a transaction publishes the salt and destroys the seal.
func CommitHash(amount int64, salt string) string {
	a := itoa(amount)
	pre := itoa(int64(len(a))) + ":" + a + itoa(int64(len(salt))) + ":" + salt
	sum := sha256.Sum256([]byte(pre))
	return hex.EncodeToString(sum[:])
}

// --- seller side ---

// CreateSale lists a lot for sealed-bid second-price sale. The caller becomes
// the seller. `reserve` is 0 (no reserve) or a floor in [MinBid, MaxBid] that
// the HIGHEST revealed bid must meet for the sale to settle. Commitments are
// accepted for `commitBlocks` blocks, then openings for `revealBlocks` blocks,
// after which anyone may [Close]. The current protocol fee is snapshotted in.
// Returns the id.
//
// `minDeposit` is the ENTRY PRICE per commitment, and it is the seller's one
// defence against slot squatting: a sale has at most MaxBiddersPerSale slots,
// a slot is never released, and a squatter who reveals a dust bid is refunded
// in full fee-free — so with no entry price a rival locks an honest bidder out
// of any sale for the cost of gas. Size it to the lot, not to the dust floor.
// 0 means "no preference", resolved to the max(MinBid, reserve) floor, which
// is the weakest setting and leaves the squatting cost at MaxBiddersPerSale
// times that floor. The floor includes the reserve because a bid under the
// reserve cannot win, so escrowing less than the reserve buys only a slot.
func CreateSale(cur realm, lot string, reserve, minDeposit, commitBlocks, revealBlocks int64) int64 {
	assertNoSend()
	seller := cur.Previous().Address()
	if len(lot) == 0 || len(lot) > MaxLotLen {
		panic("lot description must be 1.." + itoa(MaxLotLen) + " bytes")
	}
	if reserve != 0 && (reserve < MinBid || reserve > MaxBid) {
		panic("reserve must be 0 or " + itoa(MinBid) + ".." + itoa(MaxBid) + Denom)
	}
	floor := MinBid
	if reserve > floor {
		floor = reserve
	}
	if minDeposit == 0 {
		minDeposit = floor
	}
	if minDeposit < floor || minDeposit > MaxBid {
		panic("minDeposit must be 0 or " + itoa(floor) + ".." + itoa(MaxBid) + Denom +
			" (at least max(MinBid, reserve))")
	}
	if commitBlocks < MinCommitBlocks || commitBlocks > MaxWindowBlocks {
		panic("commitBlocks must be " + itoa(MinCommitBlocks) + ".." + itoa(MaxWindowBlocks))
	}
	if revealBlocks < MinRevealBlocks || revealBlocks > MaxWindowBlocks {
		panic("revealBlocks must be " + itoa(MinRevealBlocks) + ".." + itoa(MaxWindowBlocks))
	}

	n := counter(sellerNum, seller)
	if *n >= MaxSalesPerSeller {
		panic("per-seller sale limit reached")
	}

	now := runtime.ChainHeight()
	cEnd, ok := addChecked(now, commitBlocks)
	if !ok {
		panic("commit-end height overflow")
	}
	rEnd, ok := addChecked(cEnd, revealBlocks)
	if !ok {
		panic("reveal-end height overflow")
	}

	id := nextID
	nextID++
	sales.Set(padID(id), &sale{
		id:            id,
		seller:        seller,
		lot:           lot,
		reserve:       reserve,
		minDeposit:    minDeposit,
		feeBps:        feeBps,
		commitEnd:     cEnd,
		revealEnd:     rEnd,
		status:        SaleOpen,
		createdHeight: now,
		winner:        "",
	})
	*n++

	chain.Emit("SaleCreated",
		"saleId", itoa(id),
		"seller", seller.String(),
		"reserve", itoa(reserve),
		"minDeposit", itoa(minDeposit),
		"commitEnd", itoa(cEnd),
		"revealEnd", itoa(rEnd),
		"feeBps", itoa(feeBps),
	)
	return id
}

// Cancel withdraws a sale that has taken no commitment. Seller only. Once any
// commitment stands the sale can only run to Close — a seller cannot pull the
// lot out from under an escrowed bidder, and cannot strand a deposit.
func Cancel(cur realm, saleID int64) {
	assertNoSend()
	s := mustSale(saleID)
	if cur.Previous().Address() != s.seller {
		panic("only the seller may cancel")
	}
	if s.status != SaleOpen {
		panic("sale is " + s.status)
	}
	if len(s.bids) != 0 {
		panic("cannot cancel after a commitment")
	}
	s.status = SaleCancelled
	chain.Emit("SaleCancelled", "saleId", itoa(saleID), "seller", s.seller.String())
}

// --- bidder side ---

// Commit escrows a deposit behind a sealed bid. The caller attaches the
// deposit and supplies only `commitment` — [CommitHash](amount, salt) as 64
// lowercase hex characters — so the realm learns the bid's CEILING (the
// deposit) and not the bid. The deposit is the ceiling on what can later be
// opened, so escrow at least what you intend to bid; escrow more to hide it
// better. One commitment per bidder per sale, and a commitment already present
// on this sale is refused (copying another bidder's hash without knowing its
// contents would otherwise be free and could never be opened).
func Commit(cur realm, saleID int64, commitment string) {
	bidder, deposit := coinio.Receive(0, cur, Denom)
	s := mustSale(saleID)
	if s.status != SaleOpen {
		panic("sale is " + s.status)
	}
	if runtime.ChainHeight() >= s.commitEnd {
		panic("commit window has closed at height " + itoa(s.commitEnd))
	}
	if bidder == s.seller {
		panic("seller cannot bid on their own sale")
	}
	if deposit < s.minDeposit || deposit > MaxBid {
		panic("deposit must be " + itoa(s.minDeposit) + ".." + itoa(MaxBid) + Denom +
			" on this sale")
	}
	assertCommitment(commitment)
	if len(s.bids) >= MaxBiddersPerSale {
		panic("per-sale bidder limit reached")
	}
	for _, b := range s.bids {
		if b.bidder == bidder {
			panic("already committed to this sale")
		}
		if b.commitment == commitment {
			panic("that commitment is already present on this sale")
		}
	}

	s.bids = append(s.bids, &bid{
		bidder:     bidder,
		commitment: commitment,
		deposit:    deposit,
	})
	sealed += deposit

	chain.Emit("Committed",
		"saleId", itoa(saleID),
		"bidder", bidder.String(),
		"deposit", itoa(deposit),
		"commitment", commitment,
	)
}

// Reveal opens the caller's sealed bid on a sale whose commit window has shut.
// `amount` and `salt` must hash to the stored commitment, `amount` must be in
// [MinBid, MaxBid], and `amount` must not exceed the deposit — a bidder who
// committed above their escrow has no valid opening and forfeits at Close.
// Opening does not move coins; it moves the deposit from the `sealed` bucket
// to the `revealed` one and records the bid for the clearing scan.
func Reveal(cur realm, saleID int64, amount int64, salt string) {
	assertNoSend()
	bidder := cur.Previous().Address()
	s := mustSale(saleID)
	if s.status != SaleOpen {
		panic("sale is " + s.status)
	}
	now := runtime.ChainHeight()
	if now < s.commitEnd {
		panic("reveal window opens at height " + itoa(s.commitEnd))
	}
	if now >= s.revealEnd {
		panic("reveal window closed at height " + itoa(s.revealEnd))
	}
	b := findBid(s, bidder)
	if b == nil {
		panic("no commitment from caller on this sale")
	}
	if b.opened {
		panic("already revealed")
	}
	if len(salt) < MinSaltLen || len(salt) > MaxSaltLen {
		panic("salt must be " + itoa(MinSaltLen) + ".." + itoa(MaxSaltLen) + " bytes")
	}
	if amount < MinBid || amount > MaxBid {
		panic("amount must be " + itoa(MinBid) + ".." + itoa(MaxBid) + Denom)
	}
	if amount > b.deposit {
		panic("amount " + itoa(amount) + " exceeds the escrowed deposit " + itoa(b.deposit) + Denom)
	}
	if CommitHash(amount, salt) != b.commitment {
		panic("amount and salt do not match the commitment")
	}

	b.opened = true
	b.amount = amount
	s.revealCount++
	b.revealSeq = s.revealCount

	sealed -= b.deposit
	revealed += b.deposit

	chain.Emit("Revealed",
		"saleId", itoa(saleID),
		"bidder", bidder.String(),
		"amount", itoa(amount),
		"revealSeq", itoa(b.revealSeq),
	)
}

// --- close (permissionless, like every sibling realm's valve) ---

// Close settles a sale whose reveal window has shut. Anyone may call it; no
// sale's terminal state may depend on a party acting.
//
// The clearing rule: among the OPENED bids the highest wins and pays
// max(second-highest, reserve, MinBid) — a strict Vickrey price, floored so
// that a lone bidder does not win for nothing and so that a reserve is
// honoured as a price and not merely as a veto. Ties on the highest amount go
// to the EARLIEST opening, which makes the tie-break deterministic and
// independent of storage order, and a tie sets the second price equal to the
// first, so a tied winner pays their full bid.
//
// The money, all of it credited and none of it sent:
//
//   - winner: change of `deposit - price`, fee-free (it is their own coin
//     coming back, not a sale)
//   - seller: `price`, at the sale's snapshotted fee
//   - every other opened bid: its deposit back in full, fee-free
//   - every UNOPENED commitment: deposit credited to the SELLER, fee-free.
//     Fee-free is deliberate: a fee is a cut of a SALE, and taking a cut of
//     liquidated damages would give the fee recipient a revenue interest in
//     bidders failing to reveal.
//
// If no bid was opened, or the highest opened bid is below the reserve, the
// sale is Unsold: every opened bid is refunded in full and only the unopened
// commitments forfeit.
func Close(cur realm, saleID int64) {
	assertNoSend()
	s := mustSale(saleID)
	if s.status != SaleOpen {
		panic("sale is " + s.status)
	}
	if runtime.ChainHeight() < s.revealEnd {
		panic("reveal window has not closed; closes at height " + itoa(s.revealEnd))
	}

	h1, h2, winner, winnerSeq := clearing(s)

	// A sale settles only if something was opened AND it met the reserve.
	settles := winner != "" && h1 >= s.reserve
	price := int64(0)
	if settles {
		price = vickreyPrice(h2, s.reserve)
	}

	forfeited := int64(0)
	proceeds := int64(0)

	for _, b := range s.bids {
		if !b.opened {
			// Void commitment: the deposit is liquidated to the seller.
			sealed -= b.deposit
			forfeited += b.deposit
			proceeds += b.deposit
			continue
		}
		revealed -= b.deposit
		if settles && b.bidder == winner {
			// The winner pays `price` out of their deposit; the rest is change.
			// price <= b.amount <= b.deposit, proven in the package tests, so
			// change is never negative.
			change := b.deposit - price
			if change > 0 {
				ledger.MustDeposit(b.bidder.String(), change, 0)
			}
			continue
		}
		ledger.MustDeposit(b.bidder.String(), b.deposit, 0)
	}

	// Forfeits are credited fee-free; only the sale price pays the fee.
	if proceeds > 0 {
		ledger.MustDeposit(s.seller.String(), proceeds, 0)
	}
	credited, fee := int64(0), int64(0)
	if settles {
		credited, fee = ledger.MustDeposit(s.seller.String(), price, s.feeBps)
	}

	s.forfeited = forfeited
	forfeitedTotal += forfeited

	if !settles {
		s.status = SaleUnsold
		chain.Emit("SaleUnsold",
			"saleId", itoa(saleID),
			"seller", s.seller.String(),
			"revealed", itoa(s.revealCount),
			"highBid", itoa(h1),
			"reserve", itoa(s.reserve),
			"forfeited", itoa(forfeited),
		)
		return
	}

	s.status = SaleSettled
	s.winner = winner
	s.price = price
	chain.Emit("SaleSettled",
		"saleId", itoa(saleID),
		"seller", s.seller.String(),
		"winner", winner.String(),
		"winningBid", itoa(h1),
		"secondBid", itoa(h2),
		"price", itoa(price),
		"winnerSeq", itoa(winnerSeq),
		"credited", itoa(credited),
		"fee", itoa(fee),
		"forfeited", itoa(forfeited),
	)
}

// --- claims (pull: refunds, change and seller proceeds) ---

// Claim sends amount ugnot of the caller's claimable balance — refunds,
// winner's change, and seller proceeds — to the caller.
func Claim(cur realm, amount int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire claimable balance to the caller.
func ClaimAll(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// --- administration (two-step transfer, the house pattern) ---

func SetFeeBps(cur realm, bps int64) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if bps < 0 || bps > MaxFeeBps {
		panic("fee must be 0.." + itoa(MaxFeeBps) + " bps")
	}
	feeBps = bps
	chain.Emit("FeeSet", "bps", itoa(bps))
}

func SetFeeRecipient(cur realm, recipient address) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if !recipient.IsValid() {
		panic("invalid recipient")
	}
	feeRecipient = recipient
	chain.Emit("FeeRecipientSet", "to", recipient.String())
}

func WithdrawFees(cur realm) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	amount := ledger.WithdrawFees()
	if amount == 0 {
		panic("no fees accrued")
	}
	coinio.Payout(0, cur, feeRecipient, Denom, amount)
	chain.Emit("FeesWithdrawn", "to", feeRecipient.String(), "amount", itoa(amount))
}

// SweepDenom recovers out-of-band coins to the fee recipient. For the ledger
// denom the reserve is sealed + revealed + Liabilities() — escrowed deposits,
// claimable refunds, change, proceeds and the fee pot are all structurally
// unreachable.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = sealed + revealed + ledger.Liabilities()
	}
	swept := coinio.Sweep(0, cur, feeRecipient, denom, reserve)
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(swept)+denom)
}

func TransferAdmin(cur realm, successor address) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if !successor.IsValid() {
		panic("invalid successor")
	}
	pendingAdmin = successor
	chain.Emit("AdminTransferStaged", "to", successor.String())
}

func AcceptAdmin(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	if pendingAdmin == "" || caller != pendingAdmin {
		panic("no admin transfer staged for caller")
	}
	admin = pendingAdmin
	pendingAdmin = ""
	chain.Emit("AdminTransferred", "to", caller.String())
}

// --- views (non-crossing: cross-realm readable) ---

// SaleInfo returns a sale's terms and standing state. Lot text is a separate
// view ([Lot]) so this stays a numeric/address tuple.
//
// `minDeposit` is reported as RESOLVED, never as the seller typed it: a 0 at
// create means "no preference" and becomes the max(MinBid, reserve) floor, so
// a bidder reading this never has to re-derive the floor to find out what
// [Commit] will accept.
func SaleInfo(saleID int64) (seller address, reserve, minDeposit, feeBps, commitEnd, revealEnd, createdHeight, bids, revealedBids int64, status string) {
	s := mustSale(saleID)
	return s.seller, s.reserve, s.minDeposit, s.feeBps, s.commitEnd, s.revealEnd,
		s.createdHeight, int64(len(s.bids)), s.revealCount, s.status
}

// MinDeposit is the resolved entry price for one commitment on this sale: the
// smallest deposit [Commit] accepts. It is at least max(MinBid, reserve) and
// is the seller's defence against slot squatting (audit Y1; see [CreateSale]).
func MinDeposit(saleID int64) int64 { return mustSale(saleID).minDeposit }

// Lot returns the sale's free-text lot description.
func Lot(saleID int64) string { return mustSale(saleID).lot }

// Phase reports where a sale is: "commit", "reveal" or "closeable" while it is
// open, else its terminal status. The phase is derived from the chain height
// and is never stored, so it cannot disagree with the guards.
func Phase(saleID int64) string { return phaseOf(mustSale(saleID)) }

// Status is the sale's STORED state -- one of "open", "settled", "unsold" or
// "cancelled". It answers a different question from [Phase]: an open sale has
// three distinct phases but only one status, and a closed one has a status
// that no longer moves with the chain height.
func Status(saleID int64) string { return mustSale(saleID).status }

// Winner is the winning bidder once the sale has Settled, else "".
func Winner(saleID int64) address { return mustSale(saleID).winner }

// Price is the SECOND price the winner actually paid once the sale has
// Settled, else 0. It is not the winning bid; see [WinningBid].
func Price(saleID int64) int64 { return mustSale(saleID).price }

// WinningBid is the highest OPENED bid on a sale, available as soon as it is
// revealed (a revealed bid is public). It is what the winner bid, not what
// they pay.
func WinningBid(saleID int64) int64 {
	h1, _, _, _ := clearing(mustSale(saleID))
	return h1
}

// SecondBid is the second-highest OPENED bid, or 0. With a tie on the highest
// it equals the highest.
func SecondBid(saleID int64) int64 {
	_, h2, _, _ := clearing(mustSale(saleID))
	return h2
}

// ProvisionalPrice is what the winner would pay if the sale closed right now:
// max(second bid, reserve, MinBid), or 0 if nothing is opened yet or the
// highest opening is below the reserve.
func ProvisionalPrice(saleID int64) int64 {
	s := mustSale(saleID)
	if s.status == SaleSettled {
		return s.price
	}
	h1, h2, winner, _ := clearing(s)
	if winner == "" || h1 < s.reserve {
		return 0
	}
	return vickreyPrice(h2, s.reserve)
}

// CommitmentOf returns the bidder's stored commitment on a sale ("" if none).
func CommitmentOf(saleID int64, bidder address) string {
	if b := findBid(mustSale(saleID), bidder); b != nil {
		return b.commitment
	}
	return ""
}

// DepositOf returns the bidder's escrowed deposit on a sale (0 if none).
func DepositOf(saleID int64, bidder address) int64 {
	if b := findBid(mustSale(saleID), bidder); b != nil {
		return b.deposit
	}
	return 0
}

// HasRevealed reports whether the bidder has opened their bid on a sale.
func HasRevealed(saleID int64, bidder address) bool {
	b := findBid(mustSale(saleID), bidder)
	return b != nil && b.opened
}

// RevealedAmountOf returns the bidder's OPENED bid amount (0 while sealed). A
// revealed bid is public by construction — it travelled in a transaction.
func RevealedAmountOf(saleID int64, bidder address) int64 {
	b := findBid(mustSale(saleID), bidder)
	if b == nil || !b.opened {
		return 0
	}
	return b.amount
}

// ForfeitedOf is the total deposit liquidated to the seller on a closed sale
// (0 before close). A cumulative statistic, not a held balance.
func ForfeitedOf(saleID int64) int64 { return mustSale(saleID).forfeited }

// BidsOn is how many commitments a sale holds; RevealedOn how many are opened.
func BidsOn(saleID int64) int64     { return int64(len(mustSale(saleID).bids)) }
func RevealedOn(saleID int64) int64 { return mustSale(saleID).revealCount }

// BlocksLeft is how many blocks remain in the sale's current window (0 once
// the reveal window has shut or the sale is terminal).
func BlocksLeft(saleID int64) int64 {
	s := mustSale(saleID)
	if s.status != SaleOpen {
		return 0
	}
	now := runtime.ChainHeight()
	target := s.revealEnd
	if now < s.commitEnd {
		target = s.commitEnd
	}
	if left := target - now; left > 0 {
		return left
	}
	return 0
}

// IsCloseable reports whether Close would succeed right now.
func IsCloseable(saleID int64) bool {
	s := mustSale(saleID)
	return s.status == SaleOpen && runtime.ChainHeight() >= s.revealEnd
}

func HasSale(saleID int64) bool { return sales.Get(padID(saleID)) != nil }

func SalesOf(seller address) int64 {
	v := sellerNum.Get(seller.String())
	if v == nil {
		return 0
	}
	return *v.(*int64)
}

func Admin() address              { return admin }
func PendingAdmin() address       { return pendingAdmin }
func FeeRecipient() address       { return feeRecipient }
func FeeBps() int64               { return feeBps }
func NumSales() int64             { return nextID }
func ClaimableOf(a address) int64 { return ledger.BalanceOf(a.String()) }
func FeesAccrued() int64          { return ledger.FeesAccrued() }
func Liabilities() int64          { return ledger.Liabilities() }
func Sealed() int64               { return sealed }
func Revealed() int64             { return revealed }
func ForfeitedTotal() int64       { return forfeitedTotal }
func Held() int64                 { return coinio.HeldAt(self, Denom) }
func Address() address            { return self }
func Height() int64               { return runtime.ChainHeight() }

// --- internals ---

// phaseOf derives the sale's phase from the chain height. Nothing stores it,
// so it cannot disagree with the guards in Commit, Reveal and Close.
func phaseOf(s *sale) string {
	if s.status != SaleOpen {
		return s.status
	}
	now := runtime.ChainHeight()
	switch {
	case now < s.commitEnd:
		return PhaseCommit
	case now < s.revealEnd:
		return PhaseReveal
	default:
		return PhaseCloseable
	}
}

// clearing scans the opened bids of a sale for the highest and second-highest
// amounts and the winner. It is a pure read over a slice bounded by
// MaxBiddersPerSale.
//
// The result is INDEPENDENT OF STORAGE ORDER, which matters because `bids` is
// in commit order while the tie-break is on reveal order. A tie on the highest
// amount resolves to the earliest revealSeq and leaves h2 == h1, so the tied
// winner pays their full bid rather than profiting from the collision.
func clearing(s *sale) (h1, h2 int64, winner address, winnerSeq int64) {
	winner = ""
	for _, b := range s.bids {
		if !b.opened {
			continue
		}
		better := b.amount > h1 || (b.amount == h1 && winner != "" && b.revealSeq < winnerSeq)
		if better {
			h2 = h1
			h1 = b.amount
			winner = b.bidder
			winnerSeq = b.revealSeq
			continue
		}
		if b.amount > h2 {
			h2 = b.amount
		}
	}
	return h1, h2, winner, winnerSeq
}

// vickreyPrice is the clearing price: the second bid, floored by the reserve
// and by the dust floor. Each of the three is <= the winning bid in the branch
// that uses it — h2 by definition, the reserve because a lower high bid is
// Unsold, and MinBid because Reveal rejects anything under it — so the
// winner's change is never negative.
func vickreyPrice(h2, reserve int64) int64 {
	p := h2
	if reserve > p {
		p = reserve
	}
	if MinBid > p {
		p = MinBid
	}
	return p
}

func findBid(s *sale, bidder address) *bid {
	for _, b := range s.bids {
		if b.bidder == bidder {
			return b
		}
	}
	return nil
}

// assertCommitment accepts exactly CommitmentLen LOWERCASE hex characters.
// Uppercase is rejected rather than normalised: CommitHash emits lowercase, so
// an uppercase commitment could never be opened, and refusing it at Commit
// turns a silent total loss of the deposit into an immediate error.
func assertCommitment(c string) {
	if len(c) != CommitmentLen {
		panic("commitment must be " + itoa(CommitmentLen) + " lowercase hex characters")
	}
	for i := 0; i < len(c); i++ {
		ch := c[i]
		if (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') {
			continue
		}
		panic("commitment must be lowercase hex; got an invalid character")
	}
}

func mustSale(id int64) *sale {
	v := sales.Get(padID(id))
	if v == nil {
		panic("unknown sale " + itoa(id))
	}
	return v.(*sale)
}

func assertNoSend() {
	if !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func counter(tree *avl.Tree, a address) *int64 {
	k := a.String()
	if v := tree.Get(k); v != nil {
		return v.(*int64)
	}
	n := int64(0)
	tree.Set(k, &n)
	return &n
}

func addChecked(a, b int64) (int64, bool) {
	s := a + b
	if (b > 0 && s < a) || (b < 0 && s > a) {
		return 0, false
	}
	return s, true
}

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }

// --- Render ---

func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case hasPrefix(path, "sale/"):
		return renderSale(path[len("sale/"):])
	default:
		return "unknown path; try \"\" or \"sale/<id>\"\n"
	}
}

func renderHome() string {
	out := "# sealedbid — sealed-bid second-price (Vickrey) auctions in ugnot\n\n"
	out += "Sales: " + itoa(nextID) + " · sealed deposits: " + itoa(sealed) + Denom +
		" · revealed deposits: " + itoa(revealed) + Denom +
		" · claimable+fees held: " + itoa(ledger.Liabilities()) + Denom +
		" · fees accrued: " + itoa(ledger.FeesAccrued()) + Denom +
		" · forfeited to date: " + itoa(forfeitedTotal) + Denom + "\n\n"
	out += "Commit a hash of your bid and escrow a deposit; open it after the commit window shuts. " +
		"The highest opened bid wins and pays the SECOND highest price. " +
		"A commitment never opened is void and its deposit goes to the seller.\n\n"
	out += "| id | seller | lot | reserve | deposit from | phase | bids | opened | price |\n" +
		"|---|---|---|---|---|---|---|---|---|\n"
	shown := int64(0)
	for id := nextID - 1; id >= 0 && shown < RenderLimit; id-- {
		v := sales.Get(padID(id))
		if v == nil {
			continue
		}
		s := v.(*sale)
		out += "| " + itoa(s.id) + " | " + sanitize.TableCell(s.seller.String()) + " | " +
			sanitize.TableCell(s.lot) + " | " + itoa(s.reserve) + Denom + " | " +
			itoa(s.minDeposit) + Denom + " | " +
			phaseOf(s) + " | " + itoa(int64(len(s.bids))) + " | " + itoa(s.revealCount) + " | " +
			priceCell(s) + " |\n"
		shown++
	}
	if nextID > shown {
		out += "\n(" + itoa(shown) + " most recent of " + itoa(nextID) + ")\n"
	}
	return out
}

func renderSale(idStr string) string {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "bad sale id\n"
	}
	v := sales.Get(padID(id))
	if v == nil {
		return "unknown sale " + idStr + "\n"
	}
	s := v.(*sale)
	out := "# sale " + itoa(s.id) + "\n\n"
	out += "- lot: " + sanitize.InlineText(s.lot) + "\n"
	// Every stored string reaching markdown is sanitized, addresses included.
	// A bech32 address carries no markdown metacharacter, so this is not an
	// escape that is load-bearing today; it is here because renderHome already
	// routed this same field through sanitize.TableCell and this renderer did
	// not, and two renderers disagreeing about whether a field needs escaping
	// is how the next field gets the wrong answer. Audit Y2.
	out += "- seller: " + sanitize.InlineText(s.seller.String()) + "\n"
	out += "- reserve: " + itoa(s.reserve) + Denom +
		" · deposit from " + itoa(s.minDeposit) + Denom +
		" · fee: " + itoa(s.feeBps) + " bps\n"
	out += "- phase: " + phaseOf(s) + " · status: " + s.status +
		" · created at height " + itoa(s.createdHeight) + "\n"
	out += "- commit window ends at height " + itoa(s.commitEnd) +
		" · reveal window ends at height " + itoa(s.revealEnd) + "\n"
	out += "- commitments: " + itoa(int64(len(s.bids))) + " · opened: " + itoa(s.revealCount) + "\n"
	if s.status == SaleOpen {
		out += "- blocks left in this window: " + itoa(BlocksLeft(s.id)) + "\n"
		if s.revealCount > 0 {
			_, h2, _, _ := clearing(s)
			out += "- provisional second price: " + itoa(ProvisionalPrice(s.id)) + Denom +
				" (second bid " + itoa(h2) + Denom + ")\n"
		}
	}
	if s.status == SaleSettled {
		h1, h2, _, _ := clearing(s)
		out += "- winner: " + sanitize.InlineText(s.winner.String()) + " bid " + itoa(h1) + Denom +
			" and paid " + itoa(s.price) + Denom + " (second bid " + itoa(h2) + Denom + ")\n"
	}
	if s.status == SaleUnsold {
		h1, _, _, _ := clearing(s)
		out += "- unsold: highest opened bid " + itoa(h1) + Denom +
			" against reserve " + itoa(s.reserve) + Denom + "\n"
	}
	if s.forfeited > 0 {
		out += "- forfeited to the seller: " + itoa(s.forfeited) + Denom + "\n"
	}
	return out
}

func priceCell(s *sale) string {
	if s.status == SaleSettled {
		return itoa(s.price) + Denom
	}
	return "—"
}
