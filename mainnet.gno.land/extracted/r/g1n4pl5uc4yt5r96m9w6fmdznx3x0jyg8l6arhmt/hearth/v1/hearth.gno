// Package hearth escrows a single ecosystem raise in ugnot and later
// splits revenue deposits across contributors by paid share.
//
// Contribute accepts ugnot while the raise is open. Each call must be at
// least MinContribute. The running total cannot pass HardCap; excess ugnot
// is sent back to the caller. Hitting HardCap closes the raise.
//
// Raise principal (WithdrawRaise) and revenue (DepositRevenue) are separate
// ledgers. Withdrawing the raise does not change shares. After Close,
// DepositRevenue opens an epoch. Settle pays the next batch of unpaid
// wallets for that epoch. Claim pays one caller. Integer dust stays in the
// realm and is not withdrawable.
package hearth

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"math/bits"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
)

const (
	// MinContribute is the smallest ugnot a Contribute call may accept (500 GNOT).
	MinContribute int64 = 500_000_000
	// HardCap is the maximum ugnot the raise will accept (150_000 GNOT).
	HardCap int64 = 150_000_000_000
	// MaxSeats is HardCap / MinContribute. A new address past this panics.
	MaxSeats int = 300
	// MaxSettle is the most wallets one Settle call will pay.
	MaxSettle int = 20
)

// Raise window in UTC. 00:00 24 Sep 2026 through 00:00 1 Oct 2026, Vietnam (UTC+7).
// Start 2026-09-23T17:00:00Z. End 2026-09-30T17:00:00Z, exclusive.
var (
	raiseStart int64 = 1790182800
	raiseEnd   int64 = 1790787600
)

type seat struct {
	who   address
	ugnot int64
}

var (
	admin       address
	ready       bool
	closed      bool
	raised      int64
	raisedBank  int64
	revenueBank int64
	rewardBank  int64
	rewardOwed  int64
	epochCount  int
	seats       *avl.Tree
	epochs      *avl.Tree
	claimed     *avl.Tree
	handles     *avl.Tree
	owed        *avl.Tree
)

func init() {
	seats = avl.NewTree()
	epochs = avl.NewTree()
	claimed = avl.NewTree()
	handles = avl.NewTree()
	owed = avl.NewTree()
}

// Init binds the operator to the calling EOA. Once.
func Init(cur realm) {
	mustUser(cur)
	mustNoCoins()
	if ready {
		panic("hearth: already init")
	}
	admin = cur.Previous().Address()
	ready = true
	chain.Emit("Init", "admin", admin.String())
}

// SetHandle records a public X handle for the caller. Same handle is a no-op.
func SetHandle(cur realm, handle string) {
	mustUser(cur)
	mustNoCoins()
	mustReady()
	h := cleanHandle(handle)
	key := cur.Previous().Address().String()
	if prev, ok := handles.Get(key).(string); ok && prev == h {
		return
	}
	handles.Set(key, h)
	chain.Emit("Handle", "addr", key, "handle", h)
}

// Contribute accepts ugnot toward the raise.
func Contribute(cur realm) {
	mustUser(cur)
	mustReady()
	if closed {
		panic("hearth: raise closed")
	}
	got := ugnotSent()
	accept, refund, reason := planAccept(got)
	if reason != "" {
		panic("hearth: " + reason)
	}
	caller := cur.Previous().Address()
	key := caller.String()
	if curSeat, ok := seats.Get(key).(*seat); ok {
		curSeat.ugnot += accept
	} else {
		if seats.Size() >= MaxSeats {
			panic("hearth: seats full")
		}
		seats.Set(key, &seat{who: caller, ugnot: accept})
	}
	raised += accept
	raisedBank += accept
	if raised == HardCap {
		closed = true
	}
	if refund > 0 {
		send(cur, caller, refund)
	}
	chain.Emit(
		"Contributed",
		"addr", key,
		"accept", strconv.FormatInt(accept, 10),
		"refund", strconv.FormatInt(refund, 10),
		"raised", strconv.FormatInt(raised, 10),
	)
}

// Close ends the raise before the cap so revenue epochs can start.
func Close(cur realm) {
	mustUser(cur)
	mustNoCoins()
	mustAdmin(cur)
	if closed {
		panic("hearth: already closed")
	}
	if raised <= 0 {
		panic("hearth: empty raise")
	}
	closed = true
	chain.Emit("Closed", "raised", strconv.FormatInt(raised, 10))
}

// WithdrawRaise sends the operator the raise principal still on the realm.
// It does not touch revenue and does not change shares.
func WithdrawRaise(cur realm) {
	mustUser(cur)
	mustNoCoins()
	mustAdmin(cur)
	if raisedBank <= 0 {
		panic("hearth: no principal")
	}
	amt := raisedBank
	raisedBank = 0
	send(cur, admin, amt)
	chain.Emit("RaiseWithdrawn", "amount", strconv.FormatInt(amt, 10))
}

// DepositReward takes the operator's ugnot and credits each contributor
// got * seat / raised. Rounding dust stays withdrawable. Principal is unchanged.
// MinMonthlyUgnot is the monthly floor, not a cap. A larger deposit uses the same split.
func DepositReward(cur realm) {
	mustUser(cur)
	mustAdmin(cur)
	got := ugnotSent()
	if got <= 0 {
		panic("hearth: no ugnot")
	}
	if raised <= 0 {
		panic("hearth: no raise")
	}
	credited := int64(0)
	seats.Iterate("", "", func(key string, value any) bool {
		s := value.(*seat)
		share := mulDiv(got, s.ugnot, raised)
		if share <= 0 {
			return false
		}
		setOwed(key, owedOf(key)+share)
		credited += share
		return false
	})
	if credited > got {
		panic("hearth: credit")
	}
	rewardOwed += credited
	rewardBank += got - credited
	chain.Emit(
		"RewardIn",
		"amount", strconv.FormatInt(got, 10),
		"credited", strconv.FormatInt(credited, 10),
		"dust", strconv.FormatInt(got-credited, 10),
	)
}

// ClaimReward pays the caller the ugnot already credited to them.
func ClaimReward(cur realm) {
	mustUser(cur)
	mustNoCoins()
	key := cur.Previous().Address().String()
	share := owedOf(key)
	if share <= 0 {
		panic("hearth: nothing owed")
	}
	if share > rewardOwed {
		panic("hearth: owed short")
	}
	setOwed(key, 0)
	rewardOwed -= share
	send(cur, cur.Previous().Address(), share)
	chain.Emit("RewardPaid", "addr", key, "share", strconv.FormatInt(share, 10))
}

// WithdrawReward sends unallocated rounding dust back to the operator.
// amt 0 withdraws all dust. Credited shares cannot be withdrawn.
func WithdrawReward(cur realm, amt int64) {
	mustUser(cur)
	mustNoCoins()
	mustAdmin(cur)
	if amt < 0 {
		panic("hearth: bad amount")
	}
	if amt == 0 {
		amt = rewardBank
	}
	if amt <= 0 || amt > rewardBank {
		panic("hearth: pool short")
	}
	rewardBank -= amt
	send(cur, admin, amt)
	chain.Emit("RewardOut", "amount", strconv.FormatInt(amt, 10), "dust", strconv.FormatInt(rewardBank, 10))
}

// DepositRevenue opens one epoch with the attached ugnot. Raise must be closed.
func DepositRevenue(cur realm) {
	mustUser(cur)
	mustReady()
	if !closed {
		panic("hearth: raise open")
	}
	got := ugnotSent()
	if got <= 0 {
		panic("hearth: no ugnot")
	}
	epochCount++
	id := strconv.Itoa(epochCount)
	epochs.Set(id, got)
	revenueBank += got
	chain.Emit("Revenue", "epoch", id, "amount", strconv.FormatInt(got, 10))
}

// Claim pays the caller their unpaid share of one epoch.
func Claim(cur realm, epoch int) {
	mustUser(cur)
	mustNoCoins()
	key := cur.Previous().Address().String()
	pay(cur, epoch, key, true)
}

// Settle pays up to maxN unpaid seats for one epoch, in address order.
// Returns how many seats it marked this call.
func Settle(cur realm, epoch int, maxN int) int {
	mustUser(cur)
	mustNoCoins()
	if maxN < 1 || maxN > MaxSettle {
		panic("hearth: bad batch")
	}
	_ = epochAmount(epoch)
	n := 0
	seats.Iterate("", "", func(key string, _ any) bool {
		if n >= maxN {
			return true
		}
		if isClaimed(epoch, key) {
			return false
		}
		pay(cur, epoch, key, false)
		n++
		return false
	})
	chain.Emit("Settled", "epoch", strconv.Itoa(epoch), "n", strconv.Itoa(n))
	return n
}

// TransferAdmin moves the operator. The raise ledger is unchanged.
func TransferAdmin(cur realm, next address) {
	mustUser(cur)
	mustNoCoins()
	mustAdmin(cur)
	if next == admin || next == address("") {
		panic("hearth: bad admin")
	}
	admin = next
	chain.Emit("Admin", "admin", admin.String())
}

func pay(cur realm, epoch int, key string, mustPositive bool) {
	if isClaimed(epoch, key) {
		panic("hearth: already claimed")
	}
	s, ok := seats.Get(key).(*seat)
	if !ok {
		panic("hearth: no seat")
	}
	amt := epochAmount(epoch)
	share := mulDiv(amt, s.ugnot, raised)
	if share < 0 || share > revenueBank {
		panic("hearth: revenue short")
	}
	if share == 0 && mustPositive {
		panic("hearth: dust share")
	}
	markClaimed(epoch, key)
	if share == 0 {
		return
	}
	revenueBank -= share
	send(cur, s.who, share)
	chain.Emit(
		"Paid",
		"epoch", strconv.Itoa(epoch),
		"addr", key,
		"share", strconv.FormatInt(share, 10),
	)
}

// Raised is the ugnot accepted into shares.
func Raised() int64 { return raised }

// RaisedBank is principal still held for WithdrawRaise.
func RaisedBank() int64 { return raisedBank }

// RevenueBank is deposited revenue not yet paid out, including dust.
func RevenueBank() int64 { return revenueBank }

// RewardBank is the operator reward pool still on the realm.
func RewardBank() int64 { return rewardBank }

// MinMonthlyUgnot is 5% of contributed ugnot. Deposits may be larger.
// A larger deposit still splits by contribution share.
func MinMonthlyUgnot() int64 {
	if raised <= 0 {
		return 0
	}
	return mulDiv(raised, 5, 100)
}

// RewardOwed is ugnot credited to contributors and not yet claimed.
func RewardOwed() int64 { return rewardOwed }

// PoolShare is the ugnot still owed to addr from deposits already split.
func PoolShare(addr address) int64 { return owedOf(addr.String()) }

// Closed reports whether new contributions are rejected.
func Closed() bool { return closed }

// Ready reports whether Init has run.
func Ready() bool { return ready }

// RaiseStartUnix is the first second contributions are accepted, UTC.
func RaiseStartUnix() int64 { return raiseStart }

// RaiseEndUnix is the first second contributions are rejected, UTC.
func RaiseEndUnix() int64 { return raiseEnd }

// Admin is the operator address.
func Admin() address { return admin }

// SeatCount is the number of contributor addresses.
func SeatCount() int { return seats.Size() }

// EpochCount is the number of revenue deposits.
func EpochCount() int { return epochCount }

// SeatOf returns ugnot contributed by addr, or 0.
func SeatOf(addr address) int64 {
	s, ok := seats.Get(addr.String()).(*seat)
	if !ok {
		return 0
	}
	return s.ugnot
}

// HandleOf returns the stored X handle, or empty.
func HandleOf(addr address) string {
	h, ok := handles.Get(addr.String()).(string)
	if !ok {
		return ""
	}
	return h
}

// EpochAmount returns the ugnot deposited for a 1-based epoch.
func EpochAmount(epoch int) int64 { return epochAmount(epoch) }

// UserCall reports whether this crossing was a direct EOA MsgCall.
func UserCall(cur realm) bool {
	return cur.Previous().IsUserCall()
}

// AdminCall reports whether the direct caller is the operator.
func AdminCall(cur realm) bool {
	return ready && cur.Previous().IsUserCall() && cur.Previous().Address() == admin
}

// PlanAccept is the contribute decision. A non-empty reason means the call must revert.
func PlanAccept(got int64) (accept int64, refund int64, reason string) {
	return planAccept(got)
}

// ShareOf is the ugnot addr would receive for epoch. Zero if none.
func ShareOf(epoch int, addr address) int64 {
	if raised <= 0 || epoch < 1 || epoch > epochCount {
		return 0
	}
	s, ok := seats.Get(addr.String()).(*seat)
	if !ok {
		return 0
	}
	return mulDiv(epochAmount(epoch), s.ugnot, raised)
}

// Claimed reports whether addr was already paid or skipped for epoch.
func Claimed(epoch int, addr address) bool {
	return isClaimed(epoch, addr.String())
}

// Summary is a single line for clients:
// admin|raised|raisedBank|revenueBank|closed|seats|epochs|cap|min|rewardDust|rewardOwed
func Summary() string {
	flag := "0"
	if closed {
		flag = "1"
	}
	return strings.Join([]string{
		admin.String(),
		strconv.FormatInt(raised, 10),
		strconv.FormatInt(raisedBank, 10),
		strconv.FormatInt(revenueBank, 10),
		flag,
		strconv.Itoa(seats.Size()),
		strconv.Itoa(epochCount),
		strconv.FormatInt(HardCap, 10),
		strconv.FormatInt(MinContribute, 10),
		strconv.FormatInt(rewardBank, 10),
		strconv.FormatInt(rewardOwed, 10),
	}, "|")
}

// Render shows the raise terms and totals. It does not list every seat.
func Render(_ string) string {
	state := "open"
	if !ready {
		state = "awaiting init"
	} else if closed {
		state = "closed"
	}
	return strings.Join([]string{
		"# Commons",
		"",
		"One ugnot raise for the operator's gno.land products.",
		"Revenue deposits after close are split by contributed share.",
		"Contributions are not refundable. Revenue is only what is deposited.",
		"",
		"- State: " + state,
		"- Raised ugnot: " + strconv.FormatInt(raised, 10),
		"- Principal still here: " + strconv.FormatInt(raisedBank, 10),
		"- Revenue still here: " + strconv.FormatInt(revenueBank, 10),
		"- Seats: " + strconv.Itoa(seats.Size()),
		"- Epochs: " + strconv.Itoa(epochCount),
		"- Min ugnot: " + strconv.FormatInt(MinContribute, 10),
		"- Cap ugnot: " + strconv.FormatInt(HardCap, 10),
	}, "\n")
}

func planAccept(got int64) (accept int64, refund int64, reason string) {
	if !ready {
		return 0, 0, "not init"
	}
	now := time.Now().Unix()
	if now < raiseStart {
		return 0, 0, "not started"
	}
	if now >= raiseEnd {
		return 0, 0, "raise ended"
	}
	if closed {
		return 0, 0, "raise closed"
	}
	if got <= 0 {
		return 0, 0, "no ugnot"
	}
	room := HardCap - raised
	if room < MinContribute {
		return 0, 0, "cap"
	}
	accept = got
	if accept > room {
		accept = room
	}
	if accept < MinContribute {
		return 0, 0, "below min"
	}
	return accept, got - accept, ""
}

func mustUser(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("hearth: direct user call only")
	}
}

func mustReady() {
	if !ready {
		panic("hearth: not init")
	}
}

func mustAdmin(cur realm) {
	mustReady()
	if cur.Previous().Address() != admin {
		panic("hearth: operator only")
	}
}

func mustNoCoins() {
	if ugnotSent() != 0 || foreignDenom() {
		panic("hearth: unexpected coins")
	}
}

func foreignDenom() bool {
	for _, c := range unsafe.OriginSend() {
		if c.Denom != "ugnot" {
			return true
		}
	}
	return false
}

func ugnotSent() int64 {
	coins := unsafe.OriginSend()
	for _, c := range coins {
		if c.Denom != "ugnot" {
			panic("hearth: ugnot only")
		}
	}
	return coins.AmountOf("ugnot")
}

func epochAmount(epoch int) int64 {
	if epoch < 1 || epoch > epochCount {
		panic("hearth: bad epoch")
	}
	v, ok := epochs.Get(strconv.Itoa(epoch)).(int64)
	if !ok {
		panic("hearth: bad epoch")
	}
	return v
}

func claimKey(epoch int, addr string) string {
	return strconv.Itoa(epoch) + "|" + addr
}

func isClaimed(epoch int, addr string) bool {
	v, ok := claimed.Get(claimKey(epoch, addr)).(bool)
	return ok && v
}

func markClaimed(epoch int, addr string) {
	claimed.Set(claimKey(epoch, addr), true)
}

func owedOf(key string) int64 {
	v, ok := owed.Get(key).(int64)
	if !ok {
		return 0
	}
	return v
}

func setOwed(key string, n int64) {
	owed.Set(key, n)
}

func send(cur realm, to address, amt int64) {
	if amt <= 0 {
		panic("hearth: nothing to send")
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), to, chain.Coins{{Denom: "ugnot", Amount: amt}})
}

func cleanHandle(handle string) string {
	h := strings.TrimPrefix(strings.TrimSpace(handle), "@")
	if len(h) < 1 || len(h) > 15 {
		panic("hearth: bad handle")
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		if !ok {
			panic("hearth: bad handle")
		}
	}
	return h
}

const maxInt64 = int64(^uint64(0) >> 1)

func mulDiv(x, y, d int64) int64 {
	if x < 0 || y < 0 {
		panic("hearth: muldiv sign")
	}
	if d <= 0 {
		panic("hearth: muldiv divisor")
	}
	if x == 0 || y == 0 {
		return 0
	}
	hi, lo := bits.Mul64(uint64(x), uint64(y))
	if uint64(d) <= hi {
		panic("hearth: muldiv overflow")
	}
	quo, _ := bits.Div64(hi, lo, uint64(d))
	if quo > uint64(maxInt64) {
		panic("hearth: muldiv overflow")
	}
	return int64(quo)
}
