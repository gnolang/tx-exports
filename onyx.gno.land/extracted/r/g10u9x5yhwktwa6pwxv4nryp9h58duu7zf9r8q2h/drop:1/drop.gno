// Package drop is the GNOMIES meme token, its genesis claim, and its GovDAO.
//
// Supply is 10_000_000_000 units (0 decimals: 1 unit = 1 GNOMIES).
//   - 87% airdrop, pro-rata to each wallet's genesis GNOT
//   - 10% liquidity, held here until a listing vote
//   - 3% community fund, plus the pro-rata remainder, held here until a spend vote
//
// A leaf is "g1...:<amount>". Claim pays that full amount once. The
// deployer sets the claim start. The window is 90 days. Unclaimed airdrop
// is burned. Each claim must attach exactly 1 GNOT. That GNOT stays in
// this realm. There is no withdraw. GNOT and liquidity tokens leave only
// through a passed listing vote. Community tokens leave only through a
// passed spend vote. The realm does not recompute GNOT weights.
package drop

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"crypto/merkle"
	"encoding/hex"
	"math"
	"strconv"
	"time"

	"gno.land/p/g10u9x5yhwktwa6pwxv4nryp9h58duu7zf9r8q2h/grc20"
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
	// LiquidityBps is the single liquidity sleeve, 10% of supply.
	LiquidityBps int64 = 1_000
	// BpsBasis is 100%.
	BpsBasis int64 = 10_000

	// ClaimFee is the confirmation payment, 1 GNOT.
	ClaimFee int64 = 1_000_000
	// ClaimWindow is the claim period after the deployer-set start: 90 days.
	ClaimWindow int64 = 90 * 24 * 60 * 60
	// VoteWindow is how long a GovDAO proposal stays open.
	VoteWindow int64 = 7 * 24 * 60 * 60
	// quorumBps is the yes-vote floor, measured against the sealed airdrop budget.
	quorumBps int64 = 1_000

	KindSpend  = 1
	KindList   = 2
	KindSignal = 3

	maxProofAunts = 100
	hashLen       = 32
	maxMemo       = 240
)

type proposal struct {
	kind     int
	proposer address
	to       address
	tokenAmt int64
	gnotAmt  int64
	memo     string
	start    int64
	end      int64
	yes      int64
	no       int64
	executed bool
	passed   bool
}

// ballot is one address's vote. weight is the balance locked until proposal end.
type ballot struct {
	yes    bool
	weight int64
}

var (
	// publisher is the addpkg signer. Captured once, when this package is initialized.
	publisher = unsafe.OriginCaller()

	token     *grc20.Token
	ledger    *grc20.PrivateLedger
	admin     *ownable.Ownable
	adminAddr address

	escrow address

	sealed        bool
	root          []byte
	eligible      int
	allocated     int64
	communityLeft int64
	liqLeft       int64
	airdropLeft   int64
	claimStart    int64
	claimFees     int64
	burned        bool

	claimed       avl.Tree
	claimedSupply int64
	proposals     avl.Tree
	votes         avl.Tree
	nextProposal  int
)

// Init binds the addpkg signer as admin. Any other caller panics.
// The community fund stays in this realm.
func Init(cur realm) {
	mustUser(cur)
	mustNoPayment()
	if token != nil {
		panic("already initialized")
	}
	caller := cur.Previous().Address()
	if caller != publisher {
		panic("deployer")
	}
	admin = ownable.NewWithAddress(caller)
	adminAddr = caller
	escrow = cur.Address()
	token, ledger = grc20.NewToken(0, cur, "Gnomies", "GNOMIES", 0)
	chain.Emit("Init", "admin", caller.String())
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

// Seal mints the whole supply and commits the eligible-set Merkle root.
// airdropTotal is the sum of the leaf amounts, at most the 87% pool.
// Integer dust is added to the community budget inside this realm.
func Seal(cur realm, rootHex string, eligibleCount int, airdropTotal int64) {
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
	communityAmt := mintSupply * CommunityBps / BpsBasis
	liqAmt := mintSupply * LiquidityBps / BpsBasis
	pool := mintSupply - communityAmt - liqAmt
	if airdropTotal <= 0 || airdropTotal > pool {
		panic("allocated")
	}
	communityAmt += pool - airdropTotal

	mustMint(escrow, communityAmt+liqAmt+airdropTotal)

	root = append([]byte(nil), decoded...)
	eligible = eligibleCount
	allocated = airdropTotal
	communityLeft = communityAmt
	liqLeft = liqAmt
	airdropLeft = airdropTotal
	sealed = true

	chain.Emit(
		"Seal",
		"root", hex.EncodeToString(root),
		"eligible", strconv.Itoa(eligibleCount),
		"allocated", strconv.FormatInt(airdropTotal, 10),
		"community", strconv.FormatInt(communityAmt, 10),
		"liquidity", strconv.FormatInt(liqAmt, 10),
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

// Claim pays the caller's full sealed amount. Attach exactly 1 GNOT.
// That GNOT remains in this realm. There is no withdraw.
func Claim(cur realm, index int, amount int64, auntsHex string) {
	mustUser(cur)
	if !sealed {
		panic("not sealed")
	}
	if !claimOpen() {
		panic("claim closed")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent.AmountOf("ugnot") != ClaimFee {
		panic("claim fee")
	}
	if amount <= 0 || amount > allocated {
		panic("amount")
	}
	caller := cur.Previous().Address()
	key := caller.String()
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
	claimFees += ClaimFee
	claimedSupply += amount
	claimed.Set(key, amount)
	mustTransfer(escrow, caller, amount)
	chain.Emit(
		"Claim",
		"to", key,
		"index", strconv.Itoa(index),
		"amount", strconv.FormatInt(amount, 10),
	)
}

// BurnUnclaimed destroys the airdrop budget still here after the window.
// Anyone may call it. A second call reverts. GovDAO cannot recover it.
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

// Propose opens a GovDAO vote. kind is KindSpend, KindList, or KindSignal.
// The caller must already hold GNOMIES. Claims must have started.
func Propose(cur realm, kind int, to address, tokenAmt int64, gnotAmt int64, memo string) int {
	mustUser(cur)
	mustNoPayment()
	if !claimsStarted() {
		panic("claim not started")
	}
	caller := cur.Previous().Address()
	if BalanceOf(caller) <= 0 {
		panic("proposer")
	}
	switch kind {
	case KindSpend:
		if memo != "" || gnotAmt != 0 {
			panic("proposal")
		}
		if !to.IsValid() || to == escrow || tokenAmt <= 0 || tokenAmt > communityLeft {
			panic("proposal")
		}
	case KindList:
		if memo != "" {
			panic("proposal")
		}
		if !to.IsValid() || to == escrow || tokenAmt <= 0 || tokenAmt > liqLeft || gnotAmt <= 0 {
			panic("proposal")
		}
	case KindSignal:
		if to.IsValid() || tokenAmt != 0 || gnotAmt != 0 {
			panic("proposal")
		}
		if len(memo) == 0 || len(memo) > maxMemo {
			panic("proposal")
		}
	default:
		panic("proposal")
	}
	now := time.Now().Unix()
	id := nextProposal
	nextProposal++
	proposals.Set(strconv.Itoa(id), &proposal{
		kind:     kind,
		proposer: caller,
		to:       to,
		tokenAmt: tokenAmt,
		gnotAmt:  gnotAmt,
		memo:     memo,
		start:    now,
		end:      now + VoteWindow,
	})
	toText := ""
	if to.IsValid() {
		toText = to.String()
	}
	chain.Emit(
		"Propose",
		"id", strconv.Itoa(id),
		"kind", strconv.Itoa(kind),
		"proposer", caller.String(),
		"to", toText,
		"tokenAmt", strconv.FormatInt(tokenAmt, 10),
		"gnotAmt", strconv.FormatInt(gnotAmt, 10),
		"memo", memo,
	)
	return id
}

// Vote records the caller's current GNOMIES balance as yes or no.
// One vote per address. That balance stays locked until this proposal ends,
// so the same tokens cannot be counted from a second address.
func Vote(cur realm, id int, yes bool) {
	mustUser(cur)
	mustNoPayment()
	p := proposalOf(id)
	now := time.Now().Unix()
	if now < p.start || now >= p.end {
		panic("voting")
	}
	caller := cur.Previous().Address()
	key := voteKey(id, caller)
	if votes.Has(key) {
		panic("voted")
	}
	weight := BalanceOf(caller)
	if weight <= 0 {
		panic("vote weight")
	}
	votes.Set(key, &ballot{yes: yes, weight: weight})
	if yes {
		p.yes += weight
	} else {
		p.no += weight
	}
	proposals.Set(strconv.Itoa(id), p)
	yesText := "0"
	if yes {
		yesText = "1"
	}
	chain.Emit(
		"Vote",
		"id", strconv.Itoa(id),
		"yes", yesText,
		"voter", caller.String(),
		"weight", strconv.FormatInt(weight, 10),
	)
}

// Execute closes a finished proposal. A passed spend or listing moves
// only the budget that kind is allowed to move. A failed vote moves nothing.
func Execute(cur realm, id int) {
	mustCurrent(cur)
	mustNoPayment()
	if cur.Address() != escrow {
		panic("escrow")
	}
	p := proposalOf(id)
	if p.executed {
		panic("executed")
	}
	if time.Now().Unix() < p.end {
		panic("voting")
	}
	passed := p.yes > p.no && p.yes >= Quorum()
	if passed && !executable(p) {
		passed = false
	}
	p.executed = true
	p.passed = passed
	proposals.Set(strconv.Itoa(id), p)
	if !passed {
		chain.Emit("Reject", "id", strconv.Itoa(id))
		return
	}
	switch p.kind {
	case KindSpend:
		communityLeft -= p.tokenAmt
		mustTransfer(escrow, p.to, p.tokenAmt)
	case KindList:
		liqLeft -= p.tokenAmt
		mustTransfer(escrow, p.to, p.tokenAmt)
		sendGnot(cur, p.to, p.gnotAmt)
	case KindSignal:
	default:
		panic("proposal")
	}
	chain.Emit("Execute", "id", strconv.Itoa(id), "kind", strconv.Itoa(p.kind))
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
	caller := cur.Previous().Address()
	mustUnlocked(from, amount)
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

func Escrow() address      { return escrow }
func Sealed() bool         { return sealed }
func Eligible() int        { return eligible }
func Allocated() int64     { return allocated }
func CommunityLeft() int64 { return communityLeft }
func LiquidityLeft() int64 { return liqLeft }
func AirdropLeft() int64   { return airdropLeft }
func ClaimStart() int64    { return claimStart }

func ClaimEnd() int64 {
	if claimStart == 0 {
		return 0
	}
	return claimStart + ClaimWindow
}

func ClaimFees() int64   { return claimFees }
func Burned() bool       { return burned }
func Claimed() int       { return claimed.Size() }
func ProposalCount() int { return nextProposal }

func Quorum() int64 {
	if !sealed {
		return 0
	}
	return allocated * quorumBps / BpsBasis
}

func ProposalKind(id int) int       { return proposalOf(id).kind }
func ProposalYes(id int) int64      { return proposalOf(id).yes }
func ProposalNo(id int) int64       { return proposalOf(id).no }
func ProposalExecuted(id int) bool  { return proposalOf(id).executed }
func ProposalPassed(id int) bool    { return proposalOf(id).passed }
func ProposalEnd(id int) int64      { return proposalOf(id).end }
func ProposalTokenAmt(id int) int64 { return proposalOf(id).tokenAmt }
func ProposalGnotAmt(id int) int64  { return proposalOf(id).gnotAmt }
func ProposalTo(id int) address     { return proposalOf(id).to }
func ProposalMemo(id int) string    { return proposalOf(id).memo }
func ProposalProposer(id int) address {
	return proposalOf(id).proposer
}

// ClaimedSupply is the sum of leaves already paid. Burns and transfers do not change it.
func ClaimedSupply() int64 { return claimedSupply }

// Publisher is the only address allowed to call Init.
func Publisher() address { return publisher }

// Voted reports whether voter has a ballot on id. A missing ballot is (false, false).
func Voted(id int, voter address) (cast bool, yes bool) {
	if id < 0 || id >= nextProposal || !voter.IsValid() {
		return false, false
	}
	v, ok := votes.Get(voteKey(id, voter))
	if !ok {
		return false, false
	}
	b, ok := v.(*ballot)
	if !ok || b == nil {
		panic("vote")
	}
	return true, b.yes
}

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

// RealmUgnot is the GNOT balance sitting in this realm, including claim fees.
func RealmUgnot() int64 {
	if !escrow.IsValid() {
		return 0
	}
	return banker.NewReadonlyBanker().GetCoins(escrow).AmountOf("ugnot")
}

// Render shows the split, the claim window, and the GovDAO rules.
// path "proposal/<id>" prints that proposal and does not move funds.
func Render(path string) string {
	if token == nil {
		return "# GNOMIES\n\nNot initialized.\n"
	}
	const proposalPrefix = "proposal/"
	if len(path) >= len(proposalPrefix) && path[:len(proposalPrefix)] == proposalPrefix {
		return renderProposal(path[len(proposalPrefix):])
	}
	out := "# GNOMIES\n\n"
	out += ufmt.Sprintf("* **Symbol**: %s\n", token.GetSymbol())
	out += ufmt.Sprintf("* **Decimals**: %d\n", token.GetDecimals())
	out += ufmt.Sprintf("* **Total supply**: %d\n", token.TotalSupply())
	out += "* **Airdrop**: 87%, pro-rata to genesis GNOT, 100% unlocked at claim\n"
	out += "* **Claim fee**: 1 GNOT, kept in this realm\n"
	out += "* **Claim window**: 90 days from the deployer start\n"
	out += "* **Unclaimed**: burned after the window\n"
	out += "* **Liquidity**: 10%, sent only by a passed listing vote\n"
	out += "* **Community fund**: 3% plus the pro-rata remainder, sent only by a passed spend vote\n"
	out += "* **GovDAO**: holders vote 7 days, quorum 10% of the airdrop budget\n"
	out += "* **No withdraw**\n"
	if !sealed {
		out += "\nRoot is not sealed.\n"
		return out
	}
	out += ufmt.Sprintf("\n* **Eligible**: %d\n", eligible)
	out += ufmt.Sprintf("* **Airdrop budget left**: %d\n", airdropLeft)
	out += ufmt.Sprintf("* **Community left**: %d\n", communityLeft)
	out += ufmt.Sprintf("* **Liquidity left**: %d\n", liqLeft)
	out += ufmt.Sprintf("* **Claim start**: %d\n", claimStart)
	out += ufmt.Sprintf("* **Claim end**: %d\n", ClaimEnd())
	out += ufmt.Sprintf("* **Claim fees (ugnot)**: %d\n", claimFees)
	out += ufmt.Sprintf("* **Burned**: %t\n", burned)
	out += ufmt.Sprintf("* **Proposals**: %d\n", nextProposal)
	out += ufmt.Sprintf("* **Root**: %s\n", hex.EncodeToString(root))
	out += ufmt.Sprintf("* **Claimed supply**: %d\n", claimedSupply)
	return out
}

func renderProposal(idText string) string {
	id, err := strconv.Atoi(idText)
	if err != nil || id < 0 || id >= nextProposal {
		return "# GNOMIES\n\nProposal not found.\n"
	}
	p := proposalOf(id)
	toText := ""
	if p.to.IsValid() {
		toText = p.to.String()
	}
	out := ufmt.Sprintf("# GNOMIES proposal %d\n\n", id)
	out += ufmt.Sprintf("* **Kind**: %d\n", p.kind)
	out += ufmt.Sprintf("* **Proposer**: %s\n", p.proposer.String())
	out += ufmt.Sprintf("* **To**: %s\n", toText)
	out += ufmt.Sprintf("* **Token**: %d\n", p.tokenAmt)
	out += ufmt.Sprintf("* **GNOT ugnot**: %d\n", p.gnotAmt)
	out += ufmt.Sprintf("* **Memo**: %s\n", oneLine(p.memo))
	out += ufmt.Sprintf("* **Yes**: %d\n", p.yes)
	out += ufmt.Sprintf("* **No**: %d\n", p.no)
	out += ufmt.Sprintf("* **Quorum**: %d\n", Quorum())
	out += ufmt.Sprintf("* **End**: %d\n", p.end)
	out += ufmt.Sprintf("* **Executed**: %t\n", p.executed)
	out += ufmt.Sprintf("* **Passed**: %t\n", p.passed)
	return out
}

func oneLine(s string) string {
	b := []byte(s)
	for i := 0; i < len(b); i++ {
		if b[i] < 0x20 || b[i] == 0x7f {
			b[i] = ' '
		}
	}
	return string(b)
}

func leafData(bech32 string, amount int64) []byte {
	return []byte(bech32 + ":" + strconv.FormatInt(amount, 10))
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

func executable(p *proposal) bool {
	switch p.kind {
	case KindSpend:
		return p.tokenAmt > 0 && p.tokenAmt <= communityLeft && p.to.IsValid() && p.to != escrow
	case KindList:
		if p.tokenAmt <= 0 || p.tokenAmt > liqLeft || p.gnotAmt <= 0 || !p.to.IsValid() || p.to == escrow {
			return false
		}
		return RealmUgnot() >= p.gnotAmt
	case KindSignal:
		return true
	default:
		return false
	}
}

func sendGnot(cur realm, to address, amount int64) {
	mustCurrent(cur)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(escrow, to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

func proposalOf(id int) *proposal {
	if id < 0 || id >= nextProposal {
		panic("proposal")
	}
	v, ok := proposals.Get(strconv.Itoa(id))
	if !ok {
		panic("proposal")
	}
	p, ok := v.(*proposal)
	if !ok || p == nil {
		panic("proposal")
	}
	return p
}

func voteKey(id int, voter address) string {
	return strconv.Itoa(id) + ":" + voter.String()
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
// largest weight they already cast on a proposal that is still open.
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
	if !owner.IsValid() || nextProposal == 0 {
		return 0
	}
	now := time.Now().Unix()
	var max int64
	for id := 0; id < nextProposal; id++ {
		v, ok := votes.Get(voteKey(id, owner))
		if !ok {
			continue
		}
		b, ok := v.(*ballot)
		if !ok || b == nil {
			panic("vote")
		}
		if now < proposalOf(id).end && b.weight > max {
			max = b.weight
		}
	}
	return max
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
