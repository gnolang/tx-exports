// Package rooms is the on-chain trade window.
//
// Two parties share a room. Each one puts assets on their own side: native
// coins (GNOT and any other bank denom), GRC20 tokens from the registry at
// gno.land/r/nt/grc20reg/v0, and GRC721 NFTs from collections registered
// with this realm (see RegisterCollection). The realm holds the deposits.
//
// Every change to the room raises its version. A party locks the room by
// naming the exact version they reviewed, so a lock can never apply to
// contents the party has not seen. When both sides hold a lock on the
// current version, the second lock swaps everything in the same
// transaction: the maker's side goes to the taker and the taker's side
// goes to the maker.
//
// Until that moment each party can withdraw their own deposits, and either
// party can cancel the room, which returns every deposit to its owner. An
// expired room can no longer settle; its deposits stay withdrawable, and
// anyone may cancel it to send them home.
//
// A maker can also turn a room into an offer (see Offer): their side plus an
// exact list of what they want in return. The first account allowed to take
// the other seat that puts in exactly that list completes the trade in one
// transaction (see Fill).
//
// On settlement the realm keeps a service fee on coins and tokens (see
// fee.gno); NFTs, withdrawals and cancellations pay nothing.
package rooms

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"math"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	StatusOpen      = "open"
	StatusSettled   = "settled"
	StatusCancelled = "cancelled"

	// statusFilling holds a room for the length of one Fill, so nothing an
	// asset's own code runs during the transfers can change it.
	statusFilling = "filling"

	KindCoin  = "coin"
	KindToken = "token"
	KindNFT   = "nft"

	// MaxAssetsPerSide bounds the work a settlement or refund can do.
	MaxAssetsPerSide = 8

	DefaultTTLMinutes = 24 * 60
	MinTTLMinutes     = 10
	MaxTTLMinutes     = 7 * 24 * 60
)

type asset struct {
	kind   string // KindCoin, KindToken or KindNFT
	denom  string // bank denom, grc20reg key, or collection key + "#" + token id
	amount int64  // always 1 for an NFT
}

type side struct {
	owner  address
	assets []asset
	locked uint64 // version this side locked; 0 when not locked
}

// A room keeps both sides inline and its times as unix seconds: every
// separate object costs storage deposit, and a room is opened often.
type room struct {
	id       uint64
	maker    side
	taker    side
	openSeat bool // anyone may take the taker seat with Join
	// openMarket rooms take any registered asset; ordinary rooms take only
	// verified ones (see verified.gno).
	openMarket bool
	status     string
	version    uint64
	// want is the maker's standing offer: exactly what the taker must put
	// in for Fill to complete the trade. Any change to the room clears it.
	want      []asset
	feeBps    uint64 // the fee rate this room was opened with
	createdAt int64  // unix seconds of block time
	expiresAt int64
	closedAt  int64 // 0 while open
	closedBy  address
}

var (
	rooms   avl.Tree // padded id -> *room
	byParty avl.Tree // address -> []uint64 room ids, oldest first
	volume  avl.Tree // kind + ":" + denom -> int64 settled amount; NFTs count per collection

	lastID     uint64
	nSettled   uint64
	nCancelled uint64

	self address
)

func init(cur realm) {
	if !cur.IsCurrent() {
		panic("unauthorized: realm token is not current")
	}
	self = cur.Address()
	seedVerified()
	prev := cur.Previous()
	if prev.IsUserCall() && prev.Address().IsValid() {
		admin = prev.Address()
		treasury = admin
	}
}

// Open creates a room with the caller as maker and returns its id. The room
// takes only verified assets (see Verify). counterparty is the taker's
// address, or "" to leave the seat open for the first account that calls
// Join. ttlMinutes is how long the room can settle; 0 means 24 hours, and
// the allowed range is 10 minutes to 7 days.
func Open(cur realm, counterparty string, ttlMinutes int) uint64 {
	return open(cur, counterparty, ttlMinutes, false)
}

// OpenMarket is Open for a room that takes any registered asset, verified
// or not. Both parties trade unverified assets at their own risk; the app
// says so in every view of such a room.
func OpenMarket(cur realm, counterparty string, ttlMinutes int) uint64 {
	return open(cur, counterparty, ttlMinutes, true)
}

func open(cur realm, counterparty string, ttlMinutes int, openMarket bool) uint64 {
	maker := callerOf(cur)
	refuseCoins(cur)
	assertNotPaused()

	ttl := ttlMinutes
	if ttl == 0 {
		ttl = DefaultTTLMinutes
	}
	if ttl < MinTTLMinutes || ttl > MaxTTLMinutes {
		panic("room lifetime must be between 10 minutes and 7 days")
	}

	r := &room{
		maker:      side{owner: maker},
		status:     StatusOpen,
		feeBps:     openingFee(),
		openMarket: openMarket,
	}
	counterparty = strings.TrimSpace(counterparty)
	if counterparty == "" {
		r.openSeat = true
	} else {
		cp := address(counterparty)
		if !cp.IsValid() {
			panic("counterparty is not a valid address")
		}
		if cp == maker {
			panic("you cannot open a room with yourself")
		}
		r.taker.owner = cp
	}

	lastID++
	r.id = lastID
	r.version = 1
	now := time.Now().Unix()
	r.createdAt = now
	r.expiresAt = now + int64(ttl)*60

	rooms.Set(roomKey(r.id), r)
	index(maker, r.id)
	if r.taker.owner != "" {
		index(r.taker.owner, r.id)
	}

	chain.Emit("RoomOpened",
		"id", idString(r.id),
		"maker", maker.String(),
		"taker", r.taker.owner.String(),
		"expires", strconv.FormatInt(r.expiresAt, 10),
		"openMarket", strconv.FormatBool(openMarket),
	)
	return r.id
}

// Join takes the open taker seat of a room.
func Join(cur realm, roomID uint64) {
	who := callerOf(cur)
	refuseCoins(cur)
	assertNotPaused()

	r := mustRoom(roomID)
	r.assertLive()
	if !r.openSeat {
		panic("this room is invite only")
	}
	if r.taker.owner != "" {
		panic("the seat is already taken")
	}
	if who == r.maker.owner {
		panic("you opened this room")
	}
	if len(r.want) > 0 {
		panic("this room is an offer: fill it instead")
	}
	r.taker.owner = who
	index(who, r.id)
	r.bump()

	chain.Emit("RoomJoined", "id", idString(r.id), "taker", who.String())
}

// DepositCoins adds the coins sent with this call to the caller's side.
// It must be called directly from the depositing account (maketx call or a
// wallet MsgCall), because only then are the sent coins guaranteed to have
// reached this realm.
func DepositCoins(cur realm, roomID uint64) {
	if !cur.IsCurrent() {
		panic("unauthorized: realm token is not current")
	}
	prev := cur.Previous()
	// IsUserCall and OriginSend are a pair: OriginSend describes coins that
	// actually arrived here only when the caller is the signing account.
	// A code realm or a maketx run script could spend the envelope first.
	if !prev.IsUserCall() {
		panic("send coins with a direct call from your account")
	}
	who := prev.Address()
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		panic("attach the coins to this call")
	}
	assertNotPaused()

	r := mustRoom(roomID)
	r.assertLive()
	mine, _ := r.sideOf(who)
	for _, c := range sent {
		if c.Amount <= 0 {
			panic("coin amounts must be positive")
		}
		r.assertAccepts(KindCoin, c.Denom)
		mine.add(KindCoin, c.Denom, c.Amount)
	}
	r.bump()

	chain.Emit("Deposited",
		"id", idString(r.id),
		"party", who.String(),
		"coins", sent.String(),
		"version", idString(r.version),
	)
}

// DepositToken moves amount of a registered GRC20 token from the caller to
// this realm and adds it to the caller's side. The caller must first
// approve this realm's address (see Address) for at least amount.
func DepositToken(cur realm, roomID uint64, tokenKey string, amount int64) {
	who := callerOf(cur)
	refuseCoins(cur)
	assertNotPaused()
	if amount <= 0 {
		panic("amount must be positive")
	}
	if grc20reg.Get(tokenKey) == nil {
		panic("token is not in the GRC20 registry")
	}

	r := mustRoom(roomID)
	r.assertLive()
	mine, _ := r.sideOf(who)
	r.assertAccepts(KindToken, tokenKey)
	mine.assertRoomFor(KindToken, tokenKey, amount)

	// This realm is the spender: the owner's allowance to it is what moves.
	// The canonical GRC20 ledger runs no code of the token's author, so
	// nothing can call back into this realm before the deposit is recorded.
	grc20reg.TransferFrom(0, cur, tokenKey, who, cur.Address(), amount)
	mine.add(KindToken, tokenKey, amount)
	r.bump()

	chain.Emit("Deposited",
		"id", idString(r.id),
		"party", who.String(),
		"token", tokenKey,
		"amount", strconv.FormatInt(amount, 10),
		"version", idString(r.version),
	)
}

// WithdrawCoins returns amount of denom from the caller's side to the
// caller. It works while the room is open, also after it has expired or
// while the realm is paused.
func WithdrawCoins(cur realm, roomID uint64, denom string, amount int64) {
	withdraw(cur, roomID, KindCoin, denom, amount)
}

// WithdrawToken returns amount of a GRC20 token from the caller's side to
// the caller. Same rules as WithdrawCoins.
func WithdrawToken(cur realm, roomID uint64, tokenKey string, amount int64) {
	withdraw(cur, roomID, KindToken, tokenKey, amount)
}

func withdraw(cur realm, roomID uint64, kind, denom string, amount int64) {
	who := callerOf(cur)
	refuseCoins(cur)
	if amount <= 0 {
		panic("amount must be positive")
	}
	r := mustRoom(roomID)
	r.assertOpen()
	mine, _ := r.sideOf(who)
	mine.sub(kind, denom, amount)
	r.bump()

	send(cur, who, asset{kind: kind, denom: denom, amount: amount})

	chain.Emit("Withdrawn",
		"id", idString(r.id),
		"party", who.String(),
		"kind", kind,
		"denom", denom,
		"amount", strconv.FormatInt(amount, 10),
		"version", idString(r.version),
	)
}

// Lock records that the caller agrees to swap the room exactly as it is at
// version. It fails if the room has changed since. When the other side
// already holds a lock on the same version, this call settles the room and
// returns "settled"; otherwise it returns "locked".
func Lock(cur realm, roomID uint64, version uint64) string {
	who := callerOf(cur)
	refuseCoins(cur)
	assertNotPaused()

	r := mustRoom(roomID)
	r.assertLive()
	mine, theirs := r.sideOf(who)
	if r.taker.owner == "" {
		panic("waiting for a counterparty to join")
	}
	if version != r.version {
		panic("the room changed: review version " + idString(r.version) + " and lock again")
	}
	if len(r.maker.assets) == 0 || len(r.taker.assets) == 0 {
		panic("both sides need at least one asset")
	}
	r.assertStillVerified()
	if mine.locked == version {
		return "locked"
	}
	mine.locked = version

	chain.Emit("Locked",
		"id", idString(r.id),
		"party", who.String(),
		"version", idString(version),
	)

	if theirs.locked == version {
		r.settle(cur, who)
		return StatusSettled
	}
	return "locked"
}

// Unlock withdraws the caller's lock on the current version.
func Unlock(cur realm, roomID uint64) {
	who := callerOf(cur)
	refuseCoins(cur)
	r := mustRoom(roomID)
	r.assertOpen()
	mine, _ := r.sideOf(who)
	if mine.locked != r.version {
		panic("you have not locked this version")
	}
	mine.locked = 0
	if who == r.maker.owner {
		r.want = nil // the maker's lock is what an offer stands on
	}

	chain.Emit("Unlocked", "id", idString(r.id), "party", who.String())
}

// Cancel closes an open room and returns every deposit to its owner.
// Either party may cancel at any time before settlement; once the room has
// expired, anyone may cancel it.
func Cancel(cur realm, roomID uint64) {
	who := callerOf(cur)
	refuseCoins(cur)
	r := mustRoom(roomID)
	r.assertOpen()
	if !r.isParty(who) && !r.expired() {
		panic("only the two parties can cancel a room before it expires")
	}

	r.status = StatusCancelled
	r.closedAt = time.Now().Unix()
	r.closedBy = who
	nCancelled++

	for _, a := range r.maker.assets {
		send(cur, r.maker.owner, a)
	}
	if r.taker.owner != "" {
		for _, a := range r.taker.assets {
			send(cur, r.taker.owner, a)
		}
	}

	chain.Emit("Cancelled", "id", idString(r.id), "by", who.String())
}

func (r *room) settle(cur realm, by address) {
	r.status = StatusSettled
	r.closedAt = time.Now().Unix()
	r.closedBy = by
	nSettled++

	for _, a := range r.maker.assets {
		r.pay(cur, r.taker.owner, a)
		addVolume(a)
	}
	for _, a := range r.taker.assets {
		r.pay(cur, r.maker.owner, a)
		addVolume(a)
	}

	chain.Emit("Settled",
		"id", idString(r.id),
		"maker", r.maker.owner.String(),
		"taker", r.taker.owner.String(),
		"version", idString(r.version),
		"feeBps", strconv.FormatUint(r.feeBps, 10),
	)
}

// send pays one asset out of this realm's custody.
func send(cur realm, to address, a asset) {
	switch a.kind {
	case KindCoin:
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), to, chain.Coins{{Denom: a.denom, Amount: a.amount}})
	case KindToken:
		grc20reg.Transfer(0, cur, a.denom, to, a.amount)
	case KindNFT:
		sendNFT(cur, to, a.denom)
	default:
		panic("unknown asset kind")
	}
}

// assertRoomFor panics if adding amount of an asset would break a limit.
func (s *side) assertRoomFor(kind, denom string, amount int64) {
	for _, a := range s.assets {
		if a.kind == kind && a.denom == denom {
			if amount > math.MaxInt64-a.amount {
				panic("amount is too large")
			}
			return
		}
	}
	if len(s.assets) >= MaxAssetsPerSide {
		panic("a side can hold at most 8 different assets")
	}
}

func (s *side) add(kind, denom string, amount int64) {
	s.assertRoomFor(kind, denom, amount)
	for i := range s.assets {
		if s.assets[i].kind == kind && s.assets[i].denom == denom {
			s.assets[i].amount += amount
			return
		}
	}
	s.assets = append(s.assets, asset{kind: kind, denom: denom, amount: amount})
}

func (s *side) sub(kind, denom string, amount int64) {
	for i := range s.assets {
		if s.assets[i].kind != kind || s.assets[i].denom != denom {
			continue
		}
		if amount > s.assets[i].amount {
			panic("you have less than that in the room")
		}
		s.assets[i].amount -= amount
		if s.assets[i].amount == 0 {
			s.assets = append(s.assets[:i], s.assets[i+1:]...)
		}
		return
	}
	panic("you have not deposited that asset")
}

// sideOf returns the caller's side and the other side, or panics for
// anyone who is not one of the two parties.
func (r *room) sideOf(who address) (*side, *side) {
	if who == r.maker.owner {
		return &r.maker, &r.taker
	}
	if r.taker.owner != "" && who == r.taker.owner {
		return &r.taker, &r.maker
	}
	panic("only the two parties of this room can do that")
}

func (r *room) isParty(who address) bool {
	return who == r.maker.owner || (r.taker.owner != "" && who == r.taker.owner)
}

func (r *room) expired() bool {
	return time.Now().Unix() >= r.expiresAt
}

func (r *room) assertOpen() {
	if r.status != StatusOpen {
		panic("this room is " + r.status)
	}
}

// bump records a change to the room: the version moves on, so every lock on
// an earlier version stops applying, and a standing offer is withdrawn.
func (r *room) bump() {
	r.version++
	r.want = nil
}

// assertLive is assertOpen plus a check that the room can still settle.
func (r *room) assertLive() {
	r.assertOpen()
	if r.expired() {
		panic("this room has expired: withdraw or cancel to get deposits back")
	}
}

// refuseCoins stops a direct call that carries coins to any function other
// than DepositCoins. Such coins would reach this realm with nothing
// recording them; failing the call sends them back.
func refuseCoins(cur realm) {
	if !cur.IsCurrent() {
		panic("unauthorized: realm token is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this call does not take coins: use DepositCoins")
	}
}

// callerOf names the immediate caller: the realm or account that was
// current when cur was minted for this crossing call. A crossing
// function's own cur is always current, so the IsCurrent check is belt and
// braces; it keeps every identity read in the shape reviewers and the gno
// audit harness look for.
func callerOf(cur realm) address {
	if !cur.IsCurrent() {
		panic("unauthorized: realm token is not current")
	}
	return cur.Previous().Address()
}

func mustRoom(id uint64) *room {
	v := rooms.Get(roomKey(id))
	if v == nil {
		panic("room not found")
	}
	return v.(*room)
}

// index records that who is a party of room id. One growing list per
// account keeps a returning trader's next room cheap to store.
func index(who address, id uint64) {
	key := who.String()
	var ids []uint64
	if v := byParty.Get(key); v != nil {
		ids = v.([]uint64)
	}
	byParty.Set(key, append(ids, id))
}

func addVolume(a asset) {
	key := a.kind + ":" + a.denom
	if a.kind == KindNFT {
		// One entry per collection, not per token: the tree stays small.
		collection, _, _ := strings.Cut(a.denom, "#")
		key = a.kind + ":" + collection
	}
	total := int64(0)
	if v := volume.Get(key); v != nil {
		total = v.(int64)
	}
	// Volume is informational; saturate instead of failing a settlement.
	if a.amount > math.MaxInt64-total {
		total = math.MaxInt64
	} else {
		total += a.amount
	}
	volume.Set(key, total)
}

// roomKey zero-pads ids so the tree iterates in numeric order.
func roomKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	if len(s) < 20 {
		s = strings.Repeat("0", 20-len(s)) + s
	}
	return s
}

func idString(id uint64) string {
	return strconv.FormatUint(id, 10)
}
