// Package arena is a SocialFi realm: profiles, posts, follows, GNOT tips,
// and creator tickets priced on a quadratic bonding curve.
//
// Ticket collateral sits in this realm as totalReserve. Trade fees are
// forwarded out of that collateral, and Sweep only sends coins above it.
package arena

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
)

const (
	// CreatorFeeBps is the creator's cut of each ticket trade.
	CreatorFeeBps int64 = 500
	// ProtocolFeeBps is forwarded to the treasury on each ticket trade.
	ProtocolFeeBps int64 = 500
	// ReferralFeeBps is paid to the creator's referrer when they have one.
	ReferralFeeBps int64 = 100
	// TicketUnit is the ugnot price of ticket number 1. Ticket i costs i² units.
	TicketUnit int64 = 10_000
	// MaxSupply is the most tickets one creator can have outstanding.
	MaxSupply = 2000
	// MaxTrade is the most tickets one buy or sell can move.
	MaxTrade = 20
	// MaxBodyRunes is the longest post, counted in runes.
	MaxBodyRunes = 280
	// ProtocolVersion is the immutable revision of this package.
	// A later package is announced with SetSuccessor. It does not hold this reserve.
	ProtocolVersion = "1"

	maxHandle    = 16
	minHandle    = 3
	maxNameRunes = 32
	maxNameBytes = 128
	maxBioRunes  = 160
	maxBioBytes  = 640
	maxBodyBytes = 1120
)

// Profile is a copy of a member's public record.
type Profile struct {
	Addr      address
	Handle    string
	Name      string
	Bio       string
	Referrer  address
	Joined    int64
	Posts     int
	Followers int
	Following int
	TipsIn    int64
	TipsOut   int64
}

// Article is a copy of one post. Gated bodies are still stored on chain;
// Render withholds them, and GatedBody checks the caller.
type Article struct {
	ID      int
	Author  address
	Body    string
	Height  int64
	ReplyTo int
	Likes   int
	Replies int
	Tips    int64
	Gated   bool
	Deleted bool
}

type book struct {
	Supply  int
	Reserve int64
	Holders int
}

// Trees stay unexported. avl.Iterate takes a callback; handing out the
// tree would let another realm run that callback under this realm.
type store struct {
	admin        address
	treasury     address
	paused       bool
	nextID       int
	totalReserve int64
	byAddr       *avl.Tree
	byHandle     *avl.Tree
	posts        *avl.Tree
	feed         *avl.Tree
	replies      *avl.Tree
	byAuthor     *avl.Tree
	follows      *avl.Tree
	fans         *avl.Tree
	likes        *avl.Tree
	books        *avl.Tree
	shares       *avl.Tree
	successor    string
}

var state *store

func init() {
	if CreatorFeeBps < 0 || ProtocolFeeBps < 0 || ReferralFeeBps < 0 {
		panic("fees")
	}
	if CreatorFeeBps+ProtocolFeeBps+ReferralFeeBps >= 10_000 {
		panic("fees")
	}
	state = newStore()
	deployer := unsafe.OriginCaller()
	if deployer.IsValid() {
		state.admin = deployer
		state.treasury = deployer
	}
}

func newStore() *store {
	return &store{
		nextID:   1,
		byAddr:   avl.NewTree(),
		byHandle: avl.NewTree(),
		posts:    avl.NewTree(),
		feed:     avl.NewTree(),
		replies:  avl.NewTree(),
		byAuthor: avl.NewTree(),
		follows:  avl.NewTree(),
		fans:     avl.NewTree(),
		likes:    avl.NewTree(),
		books:    avl.NewTree(),
		shares:   avl.NewTree(),
	}
}

// Admin is the address allowed to pause, sweep surplus, and rotate treasury.
func Admin() address { return state.admin }

// Treasury receives protocol fees and swept surplus.
func Treasury() address { return state.treasury }

// Version is this package revision. It has no setter.
func Version() string { return ProtocolVersion }

// Successor is the package path of a later realm, or empty.
// The later realm does not receive this realm's ticket reserve.
func Successor() string { return state.successor }

// Paused reports whether new posts, replies, tips, and ticket buys are frozen.
// Sells stay open so ticket collateral can still exit.
func Paused() bool { return state.paused }

// TotalReserve is the ugnot locked to back outstanding tickets.
func TotalReserve() int64 { return state.totalReserve }

func caller(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("direct user call only")
	}
	return cur.Previous().Address()
}

func mustNoPay() {
	if len(unsafe.OriginSend()) != 0 {
		panic("this call takes no payment")
	}
}

func takeUgnot(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("direct user call only")
	}
	coins := unsafe.OriginSend()
	if len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount <= 0 {
		panic("send ugnot only")
	}
	return coins[0].Amount
}

func payout(cur realm, to address, amt int64, why string) {
	if amt == 0 {
		return
	}
	if amt < 0 || !to.IsValid() {
		panic("bad recipient: " + why)
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin("ugnot", amt)})
}

func mustAdmin(cur realm) {
	who := caller(cur)
	mustNoPay()
	if who != state.admin {
		panic("admin only")
	}
}

func pad(n int) string {
	if n < 0 {
		panic("id")
	}
	s := strconv.Itoa(n)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func validHandle(s string) bool {
	if len(s) < minHandle || len(s) > maxHandle {
		return false
	}
	alnum := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			alnum = true
		case c == '_':
		default:
			return false
		}
	}
	if !alnum || reserved(s) {
		return false
	}
	return true
}

func reserved(h string) bool {
	switch h {
	case "about", "people", "hot", "feed", "following", "admin", "arena", "u", "p", "t":
		return true
	default:
		return false
	}
}

func cleanLine(s string, maxRunes, maxBytes int, label string, allowEmpty bool) string {
	s = strings.TrimSpace(s)
	if s == "" {
		if allowEmpty {
			return ""
		}
		panic(label + " length")
	}
	if utf8.RuneCountInString(s) > maxRunes || len(s) > maxBytes {
		panic(label + " length")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 || c == 0x7f || c == '<' {
			panic(label + " has markup")
		}
	}
	return s
}

func cleanBody(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	s = strings.TrimSpace(s)
	if s == "" || utf8.RuneCountInString(s) > MaxBodyRunes || len(s) > maxBodyBytes {
		panic("body length")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\n' || c == '\t' {
			continue
		}
		if c < 0x20 || c == 0x7f || c == '<' {
			panic("body has markup")
		}
	}
	return s
}

func isYes(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "0", "no", "false", "n":
		return false
	case "1", "yes", "true", "y", "khoa":
		return true
	default:
		panic("gated must be yes or no")
	}
}

func profileByAddr(a address) *Profile {
	v := state.byAddr.Get(a.String())
	if v == nil {
		return nil
	}
	p, ok := v.(*Profile)
	if !ok {
		panic("profile type")
	}
	return p
}

func lookup(handle string) *Profile {
	h := strings.ToLower(strings.TrimSpace(handle))
	if !validHandle(h) {
		return nil
	}
	v := state.byHandle.Get(h)
	if v == nil {
		return nil
	}
	p, ok := v.(*Profile)
	if !ok {
		panic("profile type")
	}
	return p
}

func mustMember(a address) *Profile {
	p := profileByAddr(a)
	if p == nil {
		panic("register first")
	}
	return p
}

func bookOf(creator address) *book {
	v := state.books.Get(creator.String())
	if v == nil {
		panic("no book")
	}
	b, ok := v.(*book)
	if !ok {
		panic("book type")
	}
	return b
}

func postByID(id int) *Article {
	if id <= 0 {
		panic("id")
	}
	v := state.posts.Get(pad(id))
	if v == nil {
		return nil
	}
	p, ok := v.(*Article)
	if !ok {
		panic("post type")
	}
	return p
}

func shareKey(holder, creator address) string {
	return holder.String() + "/" + creator.String()
}

func getShares(holder, creator address) int {
	v := state.shares.Get(shareKey(holder, creator))
	if v == nil {
		return 0
	}
	n, ok := v.(int)
	if !ok {
		panic("share type")
	}
	return n
}

func setShares(holder, creator address, n int) {
	k := shareKey(holder, creator)
	if n == 0 {
		state.shares.Remove(k)
		return
	}
	state.shares.Set(k, n)
}

func authorKey(a address, id int) string {
	return a.String() + "/" + pad(id)
}

func followKey(from, to address) string {
	return from.String() + ">" + to.String()
}

func fanKey(creator, fan address) string {
	return creator.String() + "<" + fan.String()
}

func likeKey(id int, who address) string {
	return pad(id) + "/" + who.String()
}

// ProfileByHandle returns a copy of the profile, or false when the handle is unknown.
func ProfileByHandle(handle string) (Profile, bool) {
	p := lookup(handle)
	if p == nil {
		return Profile{}, false
	}
	return *p, true
}

// ProfileOf returns a copy of the profile bound to addr.
func ProfileOf(addr address) (Profile, bool) {
	p := profileByAddr(addr)
	if p == nil {
		return Profile{}, false
	}
	return *p, true
}

// GetPost returns a copy of the post. The copy does not alias storage.
func GetPost(id int) (Article, bool) {
	if id <= 0 {
		return Article{}, false
	}
	p := postByID(id)
	if p == nil {
		return Article{}, false
	}
	return *p, true
}

// SharesOf returns how many tickets holder has of the creator's handle.
func SharesOf(holder address, handle string) int {
	p := lookup(handle)
	if p == nil {
		panic("unknown handle")
	}
	return getShares(holder, p.Addr)
}

// SupplyOf returns tickets outstanding, ugnot locked in that curve, and holders.
func SupplyOf(handle string) (supply int, reserve int64, holders int) {
	p := lookup(handle)
	if p == nil {
		panic("unknown handle")
	}
	b := bookOf(p.Addr)
	return b.Supply, b.Reserve, b.Holders
}
