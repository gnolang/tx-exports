// Package poker is a trustless no-limit Texas Hold'em realm. See
// docs/protocol.md for the normative protocol and API.
package poker

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
)

const denom = "ugnot"

// Seat is an occupied table seat.
type Seat struct {
	Owner      address
	Session    address // empty when the owner acts directly
	Stack      int64
	SittingOut bool
	Leaving    bool // pay out and free the seat when the current hand ends
	Waiting    bool // joined during a hand, plays from the next one
}

// Table is a persistent cash table.
type Table struct {
	ID              uint64
	SmallBlind      int64
	BigBlind        int64
	MinBuyIn        int64
	MaxBuyIn        int64
	MaxPlayers      int
	ActionTimeout   int64
	ChallengeWindow int64
	ChallengeBond   int64

	Seats    []*Seat
	Button   int // seat index of the last button, -1 before the first hand
	HandNo   uint64
	Hand     *Hand
	Deck     string // raw bytes of the latest deck pass of hand DeckHand
	DeckHand uint64
}

var tables []*Table

// txCtx carries per-transaction values into helpers.
type txCtx struct {
	bk     banker.Banker
	self   address
	caller address
	height int64
}

func newCtx(cur realm) *txCtx {
	return &txCtx{
		bk:     banker.NewBanker(banker.BankerTypeRealmSend, cur),
		self:   cur.Address(),
		caller: cur.Previous().Address(),
		height: runtime.ChainHeight(),
	}
}

func (c *txCtx) pay(to address, amount int64) {
	if amount <= 0 {
		return
	}
	c.bk.SendCoins(c.self, to, chain.Coins{chain.NewCoin(denom, amount)})
}

// sentUgnot returns the ugnot attached to a direct user call and rejects any
// other denomination.
func sentUgnot(cur realm) int64 {
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		return 0
	}
	if !cur.Previous().IsUserCall() {
		panic("coins are only accepted from a direct user call")
	}
	total := int64(0)
	for _, c := range sent {
		if c.Denom != denom {
			panic("only ugnot is accepted")
		}
		total += c.Amount
	}
	return total
}

func assertNoSend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this call does not accept coins")
	}
}

func getTable(id uint64) *Table {
	if id == 0 || id > uint64(len(tables)) {
		panic("table not found")
	}
	return tables[id-1]
}

// seatOf returns the seat index for which addr is owner or session, or -1.
func (t *Table) seatOf(addr address) int {
	for i, s := range t.Seats {
		if s != nil && (s.Owner == addr || (s.Session != "" && s.Session == addr)) {
			return i
		}
	}
	return -1
}

func (t *Table) ownerSeat(addr address) int {
	for i, s := range t.Seats {
		if s != nil && s.Owner == addr {
			return i
		}
	}
	return -1
}

// handLive reports whether a hand is in progress with chips still escrowed.
func (t *Table) handLive() bool {
	return t.Hand != nil && !t.Hand.Settled
}

// inLiveHand reports whether seat i plays the live hand.
func (t *Table) inLiveHand(seat int) bool {
	if !t.handLive() {
		return false
	}
	return t.Hand.playerIndex(seat) >= 0
}

// CreateTable creates a table and returns its id.
func CreateTable(cur realm, smallBlind, bigBlind, minBuyIn, maxBuyIn int64, maxPlayers int, actionTimeoutBlocks, challengeWindowBlocks, challengeBond int64) uint64 {
	assertNoSend(cur)
	if smallBlind <= 0 || bigBlind < smallBlind {
		panic("invalid blinds")
	}
	if minBuyIn < bigBlind || maxBuyIn < minBuyIn {
		panic("invalid buy-in limits")
	}
	if maxPlayers < 2 || maxPlayers > maxSeats {
		panic("maxPlayers must be between 2 and 6")
	}
	if actionTimeoutBlocks <= 0 || challengeWindowBlocks <= 0 {
		panic("timeouts must be positive")
	}
	if challengeBond <= 0 {
		panic("challenge bond must be positive")
	}
	t := &Table{
		ID:              uint64(len(tables) + 1),
		SmallBlind:      smallBlind,
		BigBlind:        bigBlind,
		MinBuyIn:        minBuyIn,
		MaxBuyIn:        maxBuyIn,
		MaxPlayers:      maxPlayers,
		ActionTimeout:   actionTimeoutBlocks,
		ChallengeWindow: challengeWindowBlocks,
		ChallengeBond:   challengeBond,
		Seats:           make([]*Seat, maxPlayers),
		Button:          -1,
	}
	tables = append(tables, t)
	return t.ID
}

// Join takes a free seat with the attached ugnot minus gasAllowance as stack and
// forwards gasAllowance to the session address.
func Join(cur realm, tableID uint64, session string, gasAllowance int64) {
	ctx := newCtx(cur)
	t := getTable(tableID)
	sent := sentUgnot(cur)
	owner := ctx.caller
	if t.seatOf(owner) >= 0 {
		panic("already seated at this table")
	}
	if gasAllowance < 0 {
		panic("negative gas allowance")
	}
	sess := address(session)
	if session == "" {
		if gasAllowance != 0 {
			panic("gas allowance needs a session address")
		}
	} else {
		if !sess.IsValid() {
			panic("invalid session address")
		}
		if sess == owner {
			panic("session must differ from owner")
		}
		if t.seatOf(sess) >= 0 {
			panic("session address already used at this table")
		}
	}
	stack := sent - gasAllowance
	if stack < t.MinBuyIn || stack > t.MaxBuyIn {
		panic("buy-in must be between " + strconv.FormatInt(t.MinBuyIn, 10) + " and " + strconv.FormatInt(t.MaxBuyIn, 10) + " ugnot")
	}
	free := -1
	for i, s := range t.Seats {
		if s == nil {
			free = i
			break
		}
	}
	if free < 0 {
		panic("table is full")
	}
	t.Seats[free] = &Seat{Owner: owner, Session: sess, Stack: stack, Waiting: t.handLive()}
	if gasAllowance > 0 {
		ctx.pay(sess, gasAllowance)
	}
}

// TopUp adds the attached ugnot to the caller's stack between hands.
func TopUp(cur realm, tableID uint64) {
	ctx := newCtx(cur)
	t := getTable(tableID)
	sent := sentUgnot(cur)
	i := t.ownerSeat(ctx.caller)
	if i < 0 {
		panic("only the seat owner can top up")
	}
	if t.inLiveHand(i) {
		panic("cannot top up during a hand")
	}
	if sent <= 0 {
		panic("no ugnot attached")
	}
	s := t.Seats[i]
	if s.Stack+sent > t.MaxBuyIn {
		panic("stack would exceed max buy-in")
	}
	s.Stack += sent
}

// Leave pays out the stack, or marks the seat leaving until the hand ends.
func Leave(cur realm, tableID uint64) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t := getTable(tableID)
	i := t.ownerSeat(ctx.caller)
	if i < 0 {
		panic("only the seat owner can leave")
	}
	if t.inLiveHand(i) {
		t.Seats[i].Leaving = true
		return
	}
	t.removeSeat(ctx, i)
}

func (t *Table) removeSeat(ctx *txCtx, i int) {
	s := t.Seats[i]
	if s == nil {
		return
	}
	stack := s.Stack
	t.Seats[i] = nil
	ctx.pay(s.Owner, stack)
}

// SitOut skips the caller from the next hand on.
func SitOut(cur realm, tableID uint64) {
	assertNoSend(cur)
	t := getTable(tableID)
	i := t.authSeat(cur.Previous().Address())
	t.Seats[i].SittingOut = true
}

// SitIn makes the caller eligible again from the next hand.
func SitIn(cur realm, tableID uint64) {
	assertNoSend(cur)
	t := getTable(tableID)
	i := t.authSeat(cur.Previous().Address())
	t.Seats[i].SittingOut = false
}

func (t *Table) authSeat(addr address) int {
	i := t.seatOf(addr)
	if i < 0 {
		panic("caller is not seated at this table")
	}
	return i
}

// escrow returns the ugnot the realm must hold for this table.
func (t *Table) escrow() int64 {
	total := int64(0)
	for _, s := range t.Seats {
		if s != nil {
			total += s.Stack
		}
	}
	if t.handLive() {
		total += t.Hand.Bet.Pot()
	}
	return total
}

// totalEscrow is the ugnot the realm must hold across all tables.
func totalEscrow() int64 {
	total := int64(0)
	for _, t := range tables {
		total += t.escrow()
	}
	return total
}

// ChallengesEnabled reports whether this deployment accepts challenges.
func ChallengesEnabled() bool {
	return challengesEnabled
}
