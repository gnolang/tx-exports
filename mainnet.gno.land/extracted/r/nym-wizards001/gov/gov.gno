// Package gov is the WIZ GovDAO treasury, token version 4.
//
// Seal on gno.land/r/nym-wizards001/drop sends two sleeves here:
// the incentive sleeve (7% of supply) and community development
// (3% plus the pro-rata remainder). A vote spends one sleeve.
// It cannot spend the other. Liquidity was sent to the address named
// in Seal, and this realm cannot move it.
//
// Voting weight is the signer's WIZ balance. One vote per address.
// The window is 7 days, the same duration as drop.VoteWindow.
// A spend passes when yes beats no and yes reaches drop.Quorum,
// 10% of the sealed airdrop. There is no withdraw and no listing vote.
package gov

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/r/nym-wizards001/drop"
)

const (
	// KindSpend pays community WIZ to the named address.
	// The memo is optional and is not spent.
	KindSpend = 1
	// KindSignal stores a memo and moves nothing. Kind 2 is unused.
	KindSignal = 3
	// KindIncentive pays incentive WIZ to the named address.
	// The memo is optional and is not spent.
	KindIncentive = 4

	// VoteWindow matches drop.VoteWindow. A ballot locks the voter's balance for this long.
	VoteWindow int64 = 7 * 24 * 60 * 60
	// maxMemo is the packed note: a title, a summary, and a change.
	maxMemo = 1200

	notePrefix = "wizards-note/1\n"
	noteSplit  = "\n---\n"
)

type proposal struct {
	kind      int
	proposer  address
	to        address
	tokenAmt  int64
	memo      string
	start     int64
	end       int64
	yes       int64
	no        int64
	executed  bool
	passed    bool
}

type ballot struct {
	yes    bool
	weight int64
}

var (
	treasury        address
	spentCommunity  int64
	spentIncentive  int64
	proposals       avl.Tree
	votes           avl.Tree
	nextProposal    int
)

// Bind records this realm as the drop token's GovDAO.
// The transaction signer must be the token admin. One call, before Seal.
func Bind(cur realm) {
	mustUser(cur)
	mustNoPayment()
	if treasury.IsValid() {
		panic("bound")
	}
	// SetGov checks the signer before this realm records itself.
	// A rejected call must not leave treasury set.
	drop.SetGov(cross(cur))
	treasury = cur.Address()
	chain.Emit("Bind", "treasury", treasury.String())
}

// Propose opens a vote. Claims on the token must already have started.
// The caller must hold WIZ. kind is KindSpend, KindSignal, or KindIncentive.
func Propose(cur realm, kind int, to address, tokenAmt int64, memo string) int {
	mustUser(cur)
	mustNoPayment()
	if !treasury.IsValid() {
		panic("gov")
	}
	if !drop.ClaimsStarted() {
		panic("claim not started")
	}
	caller := cur.Previous().Address()
	if drop.BalanceOf(caller) <= 0 {
		panic("proposer")
	}
	switch kind {
	case KindSpend:
		if len(memo) > maxMemo {
			panic("proposal")
		}
		mustPayProposal(to, tokenAmt, CommunityLeft())
	case KindIncentive:
		if len(memo) > maxMemo {
			panic("proposal")
		}
		mustPayProposal(to, tokenAmt, IncentiveLeft())
	case KindSignal:
		if to.IsValid() || tokenAmt != 0 {
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
		"memo", memo,
	)
	return id
}

// Vote records the caller's current WIZ balance as yes or no.
// One vote per address. That balance stays locked until this proposal ends.
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
	weight := drop.BalanceOf(caller)
	if weight <= 0 {
		panic("vote weight")
	}
	drop.NoteVote(cross(cur), p.end)
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

// Execute closes a finished proposal. A passed spend pays one sleeve.
// A failed vote moves nothing. Anyone may call it.
func Execute(cur realm, id int) {
	mustCurrent(cur)
	mustNoPayment()
	p := proposalOf(id)
	if p.executed {
		panic("executed")
	}
	if time.Now().Unix() < p.end {
		panic("voting")
	}
	passed := p.yes > p.no && p.yes >= drop.Quorum()
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
		drop.Transfer(cross(cur), p.to, p.tokenAmt)
		spentCommunity += p.tokenAmt
	case KindIncentive:
		drop.Transfer(cross(cur), p.to, p.tokenAmt)
		spentIncentive += p.tokenAmt
	case KindSignal:
	default:
		panic("proposal")
	}
	chain.Emit("Execute", "id", strconv.Itoa(id), "kind", strconv.Itoa(p.kind))
}

func Treasury() int64 {
	if !treasury.IsValid() {
		return 0
	}
	return drop.BalanceOf(treasury)
}

// CommunityLeft is the community sleeve still available to a vote.
func CommunityLeft() int64 {
	return sleeveLeft(drop.CommunitySent(), spentCommunity)
}

// IncentiveLeft is the incentive sleeve still available to a vote.
func IncentiveLeft() int64 {
	return sleeveLeft(drop.IncentiveSent(), spentIncentive)
}

func TreasuryAddress() address { return treasury }

func ProposalCount() int { return nextProposal }

func ProposalKind(id int) int      { return proposalOf(id).kind }
func ProposalYes(id int) int64     { return proposalOf(id).yes }
func ProposalNo(id int) int64      { return proposalOf(id).no }
func ProposalExecuted(id int) bool { return proposalOf(id).executed }
func ProposalPassed(id int) bool   { return proposalOf(id).passed }
func ProposalEnd(id int) int64     { return proposalOf(id).end }
func ProposalTokenAmt(id int) int64 {
	return proposalOf(id).tokenAmt
}
func ProposalTo(id int) address { return proposalOf(id).to }
func ProposalMemo(id int) string {
	return proposalOf(id).memo
}
func ProposalProposer(id int) address {
	return proposalOf(id).proposer
}

// Voted reports whether voter has a ballot on id. A missing ballot is (false, false).
func Voted(id int, voter address) (cast bool, yes bool) {
	if id < 0 || id >= nextProposal || !voter.IsValid() {
		return false, false
	}
	v := votes.Get(voteKey(id, voter))
	if v == nil {
		return false, false
	}
	b, ok := v.(*ballot)
	if !ok || b == nil {
		panic("vote")
	}
	return true, b.yes
}

// Render prints one proposal at "proposal/<id>". Other paths print the treasury.
func Render(path string) string {
	const proposalPrefix = "proposal/"
	if len(path) >= len(proposalPrefix) && path[:len(proposalPrefix)] == proposalPrefix {
		return renderProposal(path[len(proposalPrefix):])
	}
	out := "# WIZ GovDAO\n\n"
	out += "* **Community development**: one sleeve, spent by a passed vote\n"
	out += "* **Incentive**: a separate sleeve, spent by a passed vote\n"
	out += "* **Liquidity**: not held here\n"
	out += "* **Vote**: WIZ balance, 7 days, quorum 10% of the sealed airdrop\n"
	out += "* **No withdraw**\n"
	if treasury.IsValid() {
		out += ufmt.Sprintf("\n* **Balance**: %d\n", Treasury())
		out += ufmt.Sprintf("* **Community left**: %d\n", CommunityLeft())
		out += ufmt.Sprintf("* **Incentive left**: %d\n", IncentiveLeft())
	}
	out += ufmt.Sprintf("* **Proposals**: %d\n", nextProposal)
	return out
}

func renderProposal(idText string) string {
	id, err := strconv.Atoi(idText)
	if err != nil || id < 0 || id >= nextProposal {
		return "# WIZ GovDAO\n\nProposal not found.\n"
	}
	p := proposalOf(id)
	toText := ""
	if p.to.IsValid() {
		toText = p.to.String()
	}
	out := ufmt.Sprintf("# WIZ proposal %d\n\n", id)
	out += ufmt.Sprintf("* **Kind**: %d\n", p.kind)
	out += ufmt.Sprintf("* **Proposer**: %s\n", p.proposer.String())
	out += ufmt.Sprintf("* **To**: %s\n", toText)
	out += ufmt.Sprintf("* **Token**: %d\n", p.tokenAmt)
	out += renderMemo(p.memo)
	out += ufmt.Sprintf("* **Yes**: %d\n", p.yes)
	out += ufmt.Sprintf("* **No**: %d\n", p.no)
	out += ufmt.Sprintf("* **Quorum**: %d\n", drop.Quorum())
	out += ufmt.Sprintf("* **End**: %d\n", p.end)
	out += ufmt.Sprintf("* **Executed**: %t\n", p.executed)
	out += ufmt.Sprintf("* **Passed**: %t\n", p.passed)
	return out
}

func renderMemo(memo string) string {
	title, summary, change, ok := splitNote(memo)
	if !ok {
		return ufmt.Sprintf("* **Memo**: %s\n", oneLine(memo))
	}
	out := ufmt.Sprintf("* **Title**: %s\n", oneLine(title))
	out += ufmt.Sprintf("* **Summary**: %s\n", oneLine(summary))
	out += ufmt.Sprintf("* **Change**: %s\n", oneLine(change))
	return out
}

func splitNote(memo string) (title, summary, change string, ok bool) {
	if len(memo) < len(notePrefix) || memo[:len(notePrefix)] != notePrefix {
		return "", "", "", false
	}
	parts := strings.SplitN(memo[len(notePrefix):], noteSplit, 3)
	if len(parts) != 3 {
		return "", "", "", false
	}
	return parts[0], parts[1], parts[2], true
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

func executable(p *proposal) bool {
	switch p.kind {
	case KindSpend:
		return payable(p, CommunityLeft())
	case KindIncentive:
		return payable(p, IncentiveLeft())
	case KindSignal:
		return true
	default:
		return false
	}
}

func payable(p *proposal, left int64) bool {
	if p.tokenAmt <= 0 || p.tokenAmt > left || !p.to.IsValid() || p.to == treasury || p.to == drop.Escrow() {
		return false
	}
	return p.tokenAmt <= drop.BalanceOf(treasury)
}

func mustPayProposal(to address, tokenAmt int64, left int64) {
	if !to.IsValid() || to == treasury || to == drop.Escrow() || tokenAmt <= 0 || tokenAmt > left || tokenAmt > drop.BalanceOf(treasury) {
		panic("proposal")
	}
}

func sleeveLeft(sent, spent int64) int64 {
	if spent < 0 || sent < spent {
		panic("sleeve")
	}
	return sent - spent
}

func proposalOf(id int) *proposal {
	if id < 0 || id >= nextProposal {
		panic("proposal")
	}
	v := proposals.Get(strconv.Itoa(id))
	if v == nil {
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

func mustNoPayment() {
	if len(unsafe.OriginSend()) != 0 {
		panic("unexpected payment")
	}
}
