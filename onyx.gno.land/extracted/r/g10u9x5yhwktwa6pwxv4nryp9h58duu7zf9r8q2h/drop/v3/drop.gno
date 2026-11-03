// Package drop is GNOMIES token version 3: the meme token and its genesis claim.
//
// Supply is 10_000_000_000 units (0 decimals: 1 unit = 1 GNOMIES).
//   - 75% airdrop, pro-rata to each wallet's genesis GNOT, paid from here
//   - 15% liquidity, minted once to the pinned wallet g17xukdzx4w0q4tmendmsjy2luxk7lvfzv39nfkl
//   - 7% liquidity incentives, minted once to the bound GovDAO realm
//   - 3% community development, plus the pro-rata remainder, minted once
//     to that same GovDAO realm
//
// A leaf is "g1...:<amount>". Claim pays that full amount once. The
// deployer sets the claim start. The window is 90 days. Unclaimed airdrop
// is burned. Claim attaches no GNOT. Any attached coins revert.
// This realm has no withdraw. It cannot move the liquidity sleeve or the
// GovDAO balance after Seal. GovDAO spends the incentive sleeve and the
// community sleeve separately.
// GovDAO lives in gno.land/r/gnomies/gov. Holders vote there.
// The realm does not recompute GNOT weights.
package drop

import (
	"chain"
	"chain/runtime/unsafe"
	"crypto/merkle"
	"encoding/hex"
	"math"
	"strconv"
	"time"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	// mintSupply is the whole GNOMIES mint. Decimals are 0.
	// TotalSupply() is the circulating supply and shrinks when leftover airdrop is burned.
	mintSupply int64 = 10_000_000_000
	// CommunityBps is 3% of supply. The pro-rata remainder is added on top.
	CommunityBps int64 = 300
	// IncentiveBps is the liquidity-incentive sleeve, 7% of supply.
	IncentiveBps int64 = 700
	// LiquidityBps is the liquidity sleeve, 15% of supply.
	LiquidityBps int64 = 1_500
	// BpsBasis is 100%.
	BpsBasis int64 = 10_000

	// ClaimWindow is the claim period after the deployer-set start: 90 days.
	ClaimWindow int64 = 90 * 24 * 60 * 60
	// VoteWindow is the longest a GovDAO ballot may lock a balance.
	// gno.land/r/gnomies/gov uses the same duration.
	VoteWindow int64 = 7 * 24 * 60 * 60
	// quorumBps is the yes-vote floor, measured against the sealed airdrop budget.
	quorumBps int64 = 1_000

	tokenVersion = "3"

	maxProofAunts = 100
	hashLen       = 32
)

// hold is the largest ballot still locking an address.
type hold struct {
	amount int64
	until  int64
}

var (
	// publisher is the addpkg signer. Captured once, when this package is initialized.
	publisher = unsafe.OriginCaller()

	token     *grc20.Token
	ledger    *grc20.PrivateLedger
	admin     *ownable.Ownable
	adminAddr address

	escrow address
	gov    address

	sealed         bool
	root           []byte
	eligible       int
	allocated      int64
	communitySent  int64
	liquidityTo    address
	liquiditySent  int64
	incentiveSent  int64
	airdropLeft    int64
	claimStart     int64
	burned         bool
	claimed        avl.Tree
	claimedSupply  int64
	locks          avl.Tree
)

// liquidityRecipient is the only wallet Seal may pay the 15% sleeve.
var liquidityRecipient = address("g17xukdzx4w0q4tmendmsjy2luxk7lvfzv39nfkl")

// Version is the token book. Version 3 sends liquidity to the named address
// and sends incentive plus community to the bound GovDAO.
func Version() string { return tokenVersion }

// Init binds the addpkg signer as admin. Any other caller panics.
func Init(cur realm) {
	mustUser(cur)
	mustNoPayment()
	if token != nil {
		panic("already initialized")
	}
	caller := cur.Previous().Address()
	// A deployed package records the addpkg signer in publisher.
	// The test VM leaves that address empty; the first Init caller is recorded.
	if !publisher.IsValid() {
		publisher = caller
	}
	if caller != publisher {
		panic("deployer")
	}
	admin = ownable.NewWithAddress(caller)
	adminAddr = caller
	escrow = cur.Address()
	token, ledger = grc20.NewToken("Gnomies", "GNOMIES", 0, 0, cur)
	chain.Emit("Init", "admin", caller.String(), "version", tokenVersion)
}

// TransferAdmin moves the admin seat. Admin cannot move funds.
func TransferAdmin(cur realm, next address) {
	mustAdmin(cur)
	mustNoPayment()
	if err := admin.TransferOwnership(0, cur, next); err != nil {
		panic(err.Error())
	}
	adminAddr = next
}

// SetGov binds the GovDAO. The caller must be that realm, and the
// transaction signer must be this token's admin. One call, before Seal.
// Seal sends both the incentive sleeve and the community sleeve there.
func SetGov(cur realm) {
	mustCurrent(cur)
	mustNoPayment()
	if token == nil {
		panic("not initialized")
	}
	if sealed {
		panic("sealed")
	}
	if gov.IsValid() {
		panic("gov set")
	}
	prev := cur.Previous()
	if prev.IsUserCall() || prev.IsUserRun() {
		panic("gov")
	}
	if unsafe.OriginCaller() != adminAddr {
		panic("admin")
	}
	caller := prev.Address()
	if !caller.IsValid() || caller == escrow {
		panic("gov")
	}
	gov = caller
	chain.Emit("SetGov", "gov", caller.String())
}

// Seal mints the whole supply, commits the eligible-set Merkle root, and
// sends the sleeves out. airdropTotal is the sum of the leaf amounts,
// at most the 75% pool. Integer dust is added to the community mint.
// liquidityTo must be liquidityRecipient. Any other address panics.
// Incentive and community both go to the realm bound with SetGov.
func Seal(cur realm, rootHex string, eligibleCount int, airdropTotal int64, liquidityToArg address) {
	mustAdmin(cur)
	mustNoPayment()
	if sealed {
		panic("already sealed")
	}
	if eligibleCount <= 0 {
		panic("eligible count")
	}
	decoded, err := hex.DecodeString(rootHex)
	if err != nil || len(decoded) != hashLen {
		panic("root")
	}
	communityAmt, incentiveAmt, liqAmt, pool := sleeves()
	if airdropTotal <= 0 || airdropTotal > pool {
		panic("allocated")
	}
	if !gov.IsValid() {
		panic("gov")
	}
	if liquidityToArg != liquidityRecipient || liquidityToArg == escrow || liquidityToArg == gov {
		panic("recipient")
	}
	communityAmt += pool - airdropTotal

	mustMint(escrow, communityAmt+incentiveAmt+liqAmt+airdropTotal)
	mustTransfer(escrow, liquidityToArg, liqAmt)
	mustTransfer(escrow, gov, incentiveAmt)
	mustTransfer(escrow, gov, communityAmt)

	root = append([]byte(nil), decoded...)
	eligible = eligibleCount
	allocated = airdropTotal
	communitySent = communityAmt
	liquidityTo = liquidityToArg
	liquiditySent = liqAmt
	incentiveSent = incentiveAmt
	airdropLeft = airdropTotal
	sealed = true

	chain.Emit(
		"Seal",
		"root", hex.EncodeToString(root),
		"eligible", strconv.Itoa(eligibleCount),
		"allocated", strconv.FormatInt(airdropTotal, 10),
		"community", strconv.FormatInt(communityAmt, 10),
		"liquidity", strconv.FormatInt(liqAmt, 10),
		"incentive", strconv.FormatInt(incentiveAmt, 10),
		"liquidityTo", liquidityToArg.String(),
		"gov", gov.String(),
	)
}

// SetClaimStart opens claims at start (unix seconds). The deployer may
// call it once. start must be in the future. Claims run for ClaimWindow.
func SetClaimStart(cur realm, start int64) {
	mustAdmin(cur)
	mustNoPayment()
	if !sealed {
		panic("not sealed")
	}
	if claimStart != 0 {
		panic("claim start set")
	}
	if start <= time.Now().Unix() || start > math.MaxInt64-ClaimWindow {
		panic("claim start")
	}
	claimStart = start
	chain.Emit(
		"SetClaimStart",
		"start", strconv.FormatInt(start, 10),
		"end", strconv.FormatInt(start+ClaimWindow, 10),
	)
}

// Claim pays the caller's full sealed amount. Attaching coins reverts.
// There is no withdraw.
func Claim(cur realm, index int, amount int64, auntsHex string) {
	var to address
	claim(cur, index, amount, auntsHex, to)
}

// ClaimTo pays the caller's full sealed amount to another address.
// The caller must still be the leaf. An invalid to pays the caller.
// to cannot be this realm. Attaching coins reverts. There is no withdraw.
func ClaimTo(cur realm, index int, amount int64, auntsHex string, to address) {
	claim(cur, index, amount, auntsHex, to)
}

func claim(cur realm, index int, amount int64, auntsHex string, to address) {
	mustUser(cur)
	mustNoPayment()
	if !sealed {
		panic("not sealed")
	}
	if !claimOpen() {
		panic("claim closed")
	}
	if amount <= 0 || amount > allocated {
		panic("amount")
	}
	caller := cur.Previous().Address()
	key := caller.String()
	dest := to
	if !dest.IsValid() {
		dest = caller
	}
	if dest == escrow {
		panic("recipient")
	}
	if index < 0 || index >= eligible {
		panic("index")
	}
	aunts, err := hex.DecodeString(auntsHex)
	if err != nil || len(aunts)%hashLen != 0 || len(aunts)/hashLen > maxProofAunts {
		panic("bad proof")
	}
	if !merkle.VerifySimpleProof(root, leafData(key, amount), index, eligible, aunts) {
		panic("bad proof")
	}
	if claimed.Has(key) {
		panic("already claimed")
	}
	if airdropLeft < amount {
		panic("airdrop empty")
	}
	airdropLeft -= amount
	claimedSupply += amount
	claimed.Set(key, amount)
	mustTransfer(escrow, dest, amount)
	chain.Emit(
		"Claim",
		"leaf", key,
		"to", dest.String(),
		"index", strconv.Itoa(index),
		"amount", strconv.FormatInt(amount, 10),
	)
}

// BurnUnclaimed destroys the airdrop budget still here after the window.
// Anyone may call it. A second call reverts. GovDAO cannot recover it.
// The sleeves already sent are not burned.
func BurnUnclaimed(cur realm) {
	mustCurrent(cur)
	if cur.Address() != escrow {
		panic("escrow")
	}
	mustNoPayment()
	if !sealed {
		panic("not sealed")
	}
	if burned {
		panic("already burned")
	}
	if claimStart == 0 || time.Now().Unix() < claimStart+ClaimWindow {
		panic("claim open")
	}
	left := airdropLeft
	airdropLeft = 0
	burned = true
	if left > 0 {
		mustBurn(escrow, left)
	}
	chain.Emit("BurnUnclaimed", "amount", strconv.FormatInt(left, 10))
}

// NoteVote locks the signing caller's current balance until until.
// Only the bound GovDAO may call it. until cannot pass VoteWindow.
func NoteVote(cur realm, until int64) {
	mustCurrent(cur)
	mustNoPayment()
	if !gov.IsValid() || cur.Previous().Address() != gov {
		panic("gov")
	}
	now := time.Now().Unix()
	if until <= now || until > now+VoteWindow {
		panic("lock")
	}
	voter := unsafe.OriginCaller()
	if !voter.IsValid() || voter == gov || voter == escrow {
		panic("voter")
	}
	weight := BalanceOf(voter)
	if weight <= 0 {
		panic("vote weight")
	}
	key := voter.String()
	amt := weight
	end := until
	if v, ok := locks.Get(key); ok {
		prev, ok := v.(*hold)
		if !ok || prev == nil {
			panic("lock")
		}
		if now < prev.until {
			if prev.amount > amt {
				amt = prev.amount
			}
			if prev.until > end {
				end = prev.until
			}
		}
	}
	locks.Set(key, &hold{amount: amt, until: end})
	chain.Emit(
		"NoteVote",
		"voter", voter.String(),
		"weight", strconv.FormatInt(amt, 10),
		"until", strconv.FormatInt(end, 10),
	)
}

func Transfer(cur realm, to address, amount int64) {
	mustCurrent(cur)
	mustToken()
	mustNoPayment()
	caller := cur.Previous().Address()
	mustUnlocked(caller, amount)
	teller := ledger.ImpersonateTeller(caller)
	if err := teller.Transfer(0, cur, to, amount); err != nil {
		panic(err.Error())
	}
}

func Approve(cur realm, spender address, amount int64) {
	mustCurrent(cur)
	mustToken()
	mustNoPayment()
	caller := cur.Previous().Address()
	teller := ledger.ImpersonateTeller(caller)
	if err := teller.Approve(0, cur, spender, amount); err != nil {
		panic(err.Error())
	}
}

func TransferFrom(cur realm, from, to address, amount int64) {
	mustCurrent(cur)
	mustToken()
	mustNoPayment()
	mustUnlocked(from, amount)
	caller := cur.Previous().Address()
	teller := ledger.ImpersonateTeller(caller)
	if err := teller.TransferFrom(0, cur, from, to, amount); err != nil {
		panic(err.Error())
	}
}

func Name() string {
	mustToken()
	return token.GetName()
}

func Symbol() string {
	mustToken()
	return token.GetSymbol()
}

func Decimals() int {
	mustToken()
	return token.GetDecimals()
}

func Supply() int64 { return TotalSupply() }

func TotalSupply() int64 {
	mustToken()
	return token.TotalSupply()
}

func GetName() string   { return Name() }
func GetSymbol() string { return Symbol() }
func GetDecimals() int  { return Decimals() }

func BalanceOf(owner address) int64 {
	mustToken()
	return token.BalanceOf(owner)
}

func Allowance(owner, spender address) int64 {
	mustToken()
	return token.Allowance(owner, spender)
}

func Admin() address { return adminAddr }

func Escrow() address       { return escrow }
func Gov() address          { return gov }
func Sealed() bool          { return sealed }
func Eligible() int         { return eligible }
func Allocated() int64      { return allocated }
func CommunitySent() int64  { return communitySent }
// LiquidityRecipient is the only address Seal accepts for the 15% sleeve.
func LiquidityRecipient() address { return liquidityRecipient }

func LiquidityTo() address { return liquidityTo }
func LiquiditySent() int64 { return liquiditySent }
func IncentiveSent() int64 { return incentiveSent }
func AirdropLeft() int64    { return airdropLeft }
func ClaimStart() int64     { return claimStart }

func ClaimEnd() int64 {
	if claimStart == 0 {
		return 0
	}
	return claimStart + ClaimWindow
}

func Burned() bool { return burned }
func Claimed() int { return claimed.Size() }

// ClaimsStarted reports whether the claim window has opened.
func ClaimsStarted() bool { return claimsStarted() }

func Quorum() int64 {
	if !sealed {
		return 0
	}
	return allocated * quorumBps / BpsBasis
}

// ClaimedSupply is the sum of leaves already paid. Burns and transfers do not change it.
func ClaimedSupply() int64 { return claimedSupply }

// Publisher is the only address allowed to call Init.
func Publisher() address { return publisher }

func RootHex() string {
	if len(root) == 0 {
		return ""
	}
	return hex.EncodeToString(root)
}

func HasClaimed(owner address) bool {
	if !owner.IsValid() {
		return false
	}
	return claimed.Has(owner.String())
}

func ClaimedOf(owner address) int64 {
	if !owner.IsValid() {
		return 0
	}
	return claimedOf(owner.String())
}

// Render shows the version-3 split and the claim window.
func Render(path string) string {
	if token == nil {
		return "# GNOMIES\n\nNot initialized.\n"
	}
	out := "# GNOMIES\n\n"
	out += ufmt.Sprintf("* **Version**: %s\n", tokenVersion)
	out += ufmt.Sprintf("* **Symbol**: %s\n", token.GetSymbol())
	out += ufmt.Sprintf("* **Decimals**: %d\n", token.GetDecimals())
	out += ufmt.Sprintf("* **Total supply**: %d\n", token.TotalSupply())
	out += "* **Airdrop**: 75%, pro-rata to genesis GNOT, 100% unlocked at claim\n"
	out += "* **Claim fee**: none\n"
	out += "* **Claim recipient**: the caller, or another address in the same call\n"
	out += "* **Claim window**: 90 days from the deployer start\n"
	out += "* **Unclaimed**: burned after the window\n"
	out += "* **Liquidity**: 15%, sent once at seal to the named address\n"
	out += "* **Incentives**: 7%, sent once at seal to GovDAO\n"
	out += "* **Community development**: 3% plus the pro-rata remainder, sent once at seal to GovDAO\n"
	out += "* **GovDAO**: a separate realm. Holders vote there on incentive and community, separately\n"
	out += "* **No withdraw**\n"
	if !sealed {
		out += "\nRoot is not sealed.\n"
		return out
	}
	out += ufmt.Sprintf("\n* **Eligible**: %d\n", eligible)
	out += ufmt.Sprintf("* **Airdrop budget left**: %d\n", airdropLeft)
	out += ufmt.Sprintf("* **Community sent**: %d\n", communitySent)
	out += ufmt.Sprintf("* **Liquidity sent**: %d\n", liquiditySent)
	out += ufmt.Sprintf("* **Incentive sent**: %d\n", incentiveSent)
	out += ufmt.Sprintf("* **Claim start**: %d\n", claimStart)
	out += ufmt.Sprintf("* **Claim end**: %d\n", ClaimEnd())
	out += ufmt.Sprintf("* **Burned**: %t\n", burned)
	out += ufmt.Sprintf("* **Root**: %s\n", hex.EncodeToString(root))
	out += ufmt.Sprintf("* **Claimed supply**: %d\n", claimedSupply)
	return out
}

func leafData(bech32 string, amount int64) []byte {
	return []byte(bech32 + ":" + strconv.FormatInt(amount, 10))
}

func sleeves() (community, incentive, liquidity, pool int64) {
	community = mintSupply * CommunityBps / BpsBasis
	incentive = mintSupply * IncentiveBps / BpsBasis
	liquidity = mintSupply * LiquidityBps / BpsBasis
	pool = mintSupply - community - incentive - liquidity
	return
}

func claimOpen() bool {
	if claimStart == 0 {
		return false
	}
	now := time.Now().Unix()
	return now >= claimStart && now < claimStart+ClaimWindow
}

func claimsStarted() bool {
	return claimStart != 0 && time.Now().Unix() >= claimStart
}

func mustCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("realm")
	}
}

func mustUser(cur realm) {
	mustCurrent(cur)
	if !cur.Previous().IsUserCall() {
		panic("user call only")
	}
}

// mustUnlocked panics when amount would push owner's balance under the
// largest weight they already cast on a ballot that is still open.
// An amount above the balance is left to the token transfer.
func mustUnlocked(owner address, amount int64) {
	if amount <= 0 {
		return
	}
	bal := BalanceOf(owner)
	if amount > bal {
		return
	}
	if bal-amount < voteLock(owner) {
		panic("vote lock")
	}
}

func voteLock(owner address) int64 {
	if !owner.IsValid() {
		return 0
	}
	v, ok := locks.Get(owner.String())
	if !ok {
		return 0
	}
	h, ok := v.(*hold)
	if !ok || h == nil {
		panic("lock")
	}
	if time.Now().Unix() >= h.until {
		return 0
	}
	return h.amount
}

func mustNoPayment() {
	if len(unsafe.OriginSend()) != 0 {
		panic("unexpected payment")
	}
}

func mustAdmin(cur realm) {
	if admin == nil || token == nil {
		panic("not initialized")
	}
	mustUser(cur)
	admin.AssertOwnedBy(cur.Previous().Address())
}

func mustToken() {
	if token == nil {
		panic("not initialized")
	}
}

func claimedOf(key string) int64 {
	v, ok := claimed.Get(key)
	if !ok {
		return 0
	}
	n, ok := v.(int64)
	if !ok {
		panic("claimed amount")
	}
	return n
}

func mustMint(to address, amount int64) {
	if err := ledger.Mint(to, amount); err != nil {
		panic(err.Error())
	}
}

func mustTransfer(from, to address, amount int64) {
	if err := ledger.Transfer(from, to, amount); err != nil {
		panic(err.Error())
	}
}

func mustBurn(from address, amount int64) {
	if err := ledger.Burn(from, amount); err != nil {
		panic(err.Error())
	}
}
