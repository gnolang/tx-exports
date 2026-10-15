// Realm: gno.land/r/<your-namespace>/feles
//
// Feles DAO — three-tier AUTHORITY governance (not weighted, not token-based).
//
//   CORE    the founding team. Final authority. Can do anything, including
//           amending the tiers themselves. Starts at 3, extensible.
//   SENATE  trusted contributors. Propose, vote, and execute within a mandate,
//           but CORE can override or veto any senate decision.
//   MEMBERS the community. Propose and signal; no binding vote.
//
// Authority is ROLE-based: a tier's power comes from its rank, not from a token
// balance or a numeric weight. Within a tier every address is one vote. A Feles
// token, if issued, is a product/treasury asset and is deliberately NOT wired
// into the tally — accumulating tokens can never buy governance power.
//
// Built on gno.land/p/nt/commondao/v0 (verified against chain/pearl source).
// Two CommonDAOs are used so each tier has real, separate voting:
//   coreDAO   — council = CORE members
//   senateDAO — council = SENATE members, parented to coreDAO for override
package feles

import (
	"chain"
	"chain/banker"
	"errors"
	"strconv"
	"time"

	"gno.land/p/g12e22uqd4jjvvsk6g95re3a44sxuephd5kkrt7m/addrset"
	"gno.land/p/g12e22uqd4jjvvsk6g95re3a44sxuephd5kkrt7m/commondao"
	"gno.land/r/demo/defi/grc20reg"
	"gno.land/r/g12e22uqd4jjvvsk6g95re3a44sxuephd5kkrt7m/feles_token"
)

// ---- genesis CORE: the founding team --------------------------------------------
// These are the operator's own keys. Whoever holds them holds FINAL AUTHORITY over
// the realm, so they are the one thing to re-check before any redeploy.
//
// commondao's supermajority is 3*yes >= 2*size: at three members, 2 of 3 carries.
//
// The third founder is not a convenience. Core membership is itself a proposal
// (ProposeAddCore/ProposeRemoveCore), so at a council of two, supermajority needs
// BOTH — and a single lost or compromised key freezes the roster, the treasury and
// minting permanently, with no path back. At three, 2-of-3 carries and one key can
// be lost. Its key was generated off this box, so it survives losing this machine.
var coreSeed = []address{
	"g12e22uqd4jjvvsk6g95re3a44sxuephd5kkrt7m", // Astake — deployer
	"g180zn65f9h588p6qnrh8gnjccgdt2mvpxnzy7us", // Bstake
	"g1q3a9jxqjxppszt84xy3kuw96srkexwk9ujqlvh", // Cstake — off-box
}

var (
	coreDAO   *commondao.CommonDAO // tier 1 — final authority
	senateDAO *commondao.CommonDAO // tier 2 — mandated authority, CORE can override
	memberSet = &addrset.Set{}     // tier 3 — proposal + signal rights only
)

func init() {
	coreOpts := []commondao.Option{
		commondao.WithName("Feles Core"),
		commondao.WithPurpose("Final authority over Feles governance and treasury"),
		commondao.WithProposalKind(treasurySpendKind{}),
		commondao.WithProposalKind(tokenSpendKind{}),
		commondao.WithProposalKind(mintKind{}),
		commondao.WithProposalKind(burnKind{}),
		commondao.WithProposalKind(coreRosterKind{}),
		commondao.WithProposalKind(authorityKind{}),
	}
	for _, a := range coreSeed {
		coreOpts = append(coreOpts, commondao.WithCouncilMember(a))
	}
	coreDAO = commondao.New(coreOpts...)

	// Senate is parented to Core: that parent link is what makes CORE's authority
	// structural rather than a convention we have to re-check by hand.
	senateDAO = commondao.New(
		commondao.WithName("Feles Senate"),
		commondao.WithPurpose("Delegated authority under Core"),
		commondao.WithParent(coreDAO),
		commondao.WithProposalKind(treasurySpendKind{}),
		commondao.WithProposalKind(tokenSpendKind{}),
	)
}

// ---- tier membership -------------------------------------------------------
// Every tier change is a CORE action. Authority flows downward only.

// CORE MEMBERSHIP IS THE ONE POWER A CORE MEMBER DOES NOT HOLD ALONE. It moves only
// through a core proposal — ProposeAddCore / ProposeRemoveCore, down with the other
// proposal kinds. A direct AddCore/RemoveCore existed here once and was removed: with
// a small council, one member could eject the others and become sole final authority,
// which makes the supermajority on spending worthless. A threshold on the treasury
// means nothing if the roster that decides who votes can be rewritten by one caller.
//
// The senate roster below stays unilateral deliberately. That is Core exercising
// authority DOWNWARD over a delegated tier, not a core member rewriting their peers.

func AddSenator(cur realm, who address) {
	assertCore(cur)
	if err := senateDAO.UpdateCouncil([]address{who}, nil); err != nil {
		panic(err)
	}
	chain.Emit("SenatorAdded", "who", who.String(), "by", cur.Previous().Address().String())
}

// CORE removes a senator unilaterally — this is the override in practice.
//
// commondao refuses an update that would empty a council (ErrEmptyCouncil), so the
// LAST senator cannot be removed this way. That invariant is a feature for CORE — the
// realm can never become ownerless — but it would otherwise cap CORE's authority over
// the senate. SuspendSenate below is the answer: it disbands the senate's powers
// without violating the library's invariant.
func RemoveSenator(cur realm, who address) {
	assertCore(cur)
	if err := senateDAO.UpdateCouncil(nil, []address{who}); err != nil {
		if err == commondao.ErrEmptyCouncil {
			panic(errors.New("feles: cannot remove the last senator; use SuspendSenate"))
		}
		panic(err)
	}
	chain.Emit("SenatorRemoved", "who", who.String(), "by", cur.Previous().Address().String())
}

// ---- suspension: CORE disbands the senate's powers wholesale --------------------
// A suspended senate keeps its roster but can do nothing: no new proposals, no votes,
// no execution. This is the disband that ErrEmptyCouncil denies us structurally.

var senateSuspended bool

func SuspendSenate(cur realm) {
	assertCore(cur)
	senateSuspended = true
	chain.Emit("SenateSuspended", "by", cur.Previous().Address().String())
}

func ResumeSenate(cur realm) {
	assertCore(cur)
	senateSuspended = false
	chain.Emit("SenateResumed", "by", cur.Previous().Address().String())
}

func IsSenateSuspended() bool { return senateSuspended }

func assertSenateActive() {
	if senateSuspended {
		panic(errors.New("feles: senate is suspended by core"))
	}
}

// Senate admits members; Core may also admit or remove.
func AddMember(cur realm, who address) {
	caller := cur.Previous().Address()
	if !isCore(caller) && !isSenator(caller) {
		panic(errors.New("feles: core or senate only"))
	}
	memberSet.Add(who)
	chain.Emit("MemberAdded", "who", who.String(), "by", caller.String())
}

func RemoveMember(cur realm, who address) {
	assertCore(cur)
	memberSet.Remove(who)
	chain.Emit("MemberRemoved", "who", who.String(), "by", cur.Previous().Address().String())
}

// ---- proposals -------------------------------------------------------------
// Anyone in any tier may OPEN a treasury proposal. Where it is opened decides
// who votes on it: senate proposals are senate-voted, core proposals core-voted.

func ProposeToSenate(cur realm, to address, denom string, amount int64) uint64 {
	caller := cur.Previous().Address()
	if !isCore(caller) && !isSenator(caller) && !memberSet.Has(caller) {
		panic(errors.New("feles: not a member of any tier"))
	}
	assertSenateActive()
	p, err := senateDAO.Propose(caller, "treasury_spend", spendArgs{to, denom, amount})
	if err != nil {
		panic(err)
	}
	emitProposalOpened(p.ID(), "senate", "treasury_spend", caller)
	return p.ID()
}

func ProposeToCore(cur realm, to address, denom string, amount int64) uint64 {
	caller := cur.Previous().Address()
	if !isCore(caller) && !isSenator(caller) {
		panic(errors.New("feles: core or senate may escalate to core"))
	}
	p, err := coreDAO.Propose(caller, "treasury_spend", spendArgs{to, denom, amount})
	if err != nil {
		panic(err)
	}
	emitProposalOpened(p.ID(), "core", "treasury_spend", caller)
	return p.ID()
}

// ---- GRC20 treasury -------------------------------------------------------------
// The treasury is multi-asset: native coins (above) and any GRC20 registered in
// r/demo/defi/grc20reg. tokenKey is that registry key, e.g.
// "gno.land/r/<addr>/feles_token.feles". Same tiers, same veto, same suspension —
// only the asset differs.

func ProposeTokenToSenate(cur realm, tokenKey string, to address, amount int64) uint64 {
	caller := cur.Previous().Address()
	if !isCore(caller) && !isSenator(caller) && !memberSet.Has(caller) {
		panic(errors.New("feles: not a member of any tier"))
	}
	assertSenateActive()
	p, err := senateDAO.Propose(caller, "treasury_token_spend", tokenSpendArgs{tokenKey, to, amount})
	if err != nil {
		panic(err)
	}
	emitProposalOpened(p.ID(), "senate", "treasury_token_spend", caller)
	return p.ID()
}

func ProposeTokenToCore(cur realm, tokenKey string, to address, amount int64) uint64 {
	caller := cur.Previous().Address()
	if !isCore(caller) && !isSenator(caller) {
		panic(errors.New("feles: core or senate may escalate to core"))
	}
	p, err := coreDAO.Propose(caller, "treasury_token_spend", tokenSpendArgs{tokenKey, to, amount})
	if err != nil {
		panic(err)
	}
	emitProposalOpened(p.ID(), "core", "treasury_token_spend", caller)
	return p.ID()
}

func VoteSenate(cur realm, proposalID uint64, choice commondao.VoteChoice, reason string) {
	caller := cur.Previous().Address()
	if !isSenator(caller) {
		panic(errors.New("feles: senate only"))
	}
	assertSenateActive()
	if err := senateDAO.Vote(caller, proposalID, choice, reason); err != nil {
		panic(err)
	}
	emitVote(proposalID, "senate", caller, choice)
}

func VoteCore(cur realm, proposalID uint64, choice commondao.VoteChoice, reason string) {
	caller := cur.Previous().Address()
	assertCore(cur)
	if err := coreDAO.Vote(caller, proposalID, choice, reason); err != nil {
		panic(err)
	}
	emitVote(proposalID, "core", caller, choice)
}

// ---- execution + override --------------------------------------------------

func ExecuteSenate(cur realm, proposalID uint64) {
	caller := cur.Previous().Address()
	if !isSenator(caller) && !isCore(caller) {
		panic(errors.New("feles: senate or core only"))
	}
	// CORE's override, enforced at the gate: a vetoed proposal never executes,
	// however the senate voted.
	if vetoed[proposalID] {
		panic(errors.New("feles: proposal vetoed by core"))
	}
	assertSenateActive()
	if err := senateDAO.Execute(proposalID, cur); err != nil {
		panic(err)
	}
	assertExecuted(senateDAO, proposalID)
	chain.Emit("ProposalExecuted", "id", strconv.FormatUint(proposalID, 10),
		"tier", "senate", "by", caller.String())
}

func ExecuteCore(cur realm, proposalID uint64) {
	assertCore(cur)
	if err := coreDAO.Execute(proposalID, cur); err != nil {
		panic(err)
	}
	assertExecuted(coreDAO, proposalID)
	chain.Emit("ProposalExecuted", "id", strconv.FormatUint(proposalID, 10),
		"tier", "core", "by", cur.Previous().Address().String())
}

// commondao deliberately treats an executor error as a FAILED PROPOSAL rather than a
// failed call: "any error is going to result in a proposal failure and execute will
// succeed" (commondao.gno). So Execute returns nil and the reason is buried in the
// proposal's status. For a treasury that is unacceptable — a spend that silently did
// nothing would look identical to one that paid out. Surface it.
func assertExecuted(dao *commondao.CommonDAO, proposalID uint64) {
	p := dao.GetProposal(proposalID)
	if p == nil {
		return // dismissed proposals are not an execution failure
	}
	if p.Status() == commondao.StatusFailed {
		panic(errors.New("feles: proposal " + string(p.Status()) + ": " + p.StatusReason()))
	}
}

// ProposalStatus exposes how a proposal ended, and why if it failed — the pair a
// treasury operator actually needs after calling Execute.
func ProposalStatus(proposalID uint64, senate bool) string {
	dao := coreDAO
	if senate {
		dao = senateDAO
	}
	p := dao.GetProposal(proposalID)
	if p == nil {
		return "not found"
	}
	if r := p.StatusReason(); r != "" {
		return string(p.Status()) + ": " + r
	}
	return string(p.Status())
}

// The explicit CORE veto. commondao's `dismiss` is UNEXPORTED and a parent DAO
// has no library-level power over a child's proposals, so the override cannot be
// delegated to the framework — it is enforced here, at the execution gate.
// ExecuteSenate consults this set, so a vetoed proposal can pass its senate vote
// and still never execute. That is what makes CORE final authority in practice.
var vetoed = map[uint64]bool{}

func VetoSenateProposal(cur realm, proposalID uint64) {
	assertCore(cur)
	vetoed[proposalID] = true
	chain.Emit("ProposalVetoed", "id", strconv.FormatUint(proposalID, 10),
		"by", cur.Previous().Address().String())
}

// CORE can also lift its own veto.
func UnvetoSenateProposal(cur realm, proposalID uint64) {
	assertCore(cur)
	delete(vetoed, proposalID)
	chain.Emit("ProposalUnvetoed", "id", strconv.FormatUint(proposalID, 10),
		"by", cur.Previous().Address().String())
}

func IsVetoed(proposalID uint64) bool { return vetoed[proposalID] }

// ---- the custom proposal kind: treasury spend ------------------------------

type spendArgs struct {
	to     address
	denom  string
	amount int64
}

type treasurySpendKind struct{}

func (treasurySpendKind) Name() string { return "treasury_spend" }

func (treasurySpendKind) New(_ commondao.ReadonlyCommonDAO, args any) (commondao.ProposalDefinition, error) {
	a, ok := args.(spendArgs)
	if !ok {
		return nil, errors.New("feles: bad treasury_spend args")
	}
	if a.amount <= 0 || a.denom == "" {
		return nil, errors.New("feles: invalid spend")
	}
	// The native banker does NOT validate the destination — a spend to a malformed
	// address succeeds and the coins are gone. GRC20 rejects it, so only the native
	// path is exposed. Check here, at proposal time, so nobody votes on a burn.
	if !a.to.IsValid() {
		return nil, errors.New("feles: invalid recipient address")
	}
	return spendDef{a}, nil
}

type spendDef struct{ a spendArgs }

func (spendDef) Title() string { return "Treasury spend" }

// Body carries the ACTUAL parameters, not a description of the kind. It is what
// Render and gnoweb show a voter, and "Send coins from the Feles treasury" tells
// them nothing about what they are voting on.
func (d spendDef) Body() string {
	return "Send " + strconv.FormatInt(d.a.amount, 10) + d.a.denom + " to " + d.a.to.String()
}
func (spendDef) VotingPeriod() time.Duration    { return 7 * 24 * time.Hour }
func (spendDef) Threshold() commondao.Threshold { return commondao.ThresholdSupermajority }

func (d spendDef) Executor() commondao.ExecFunc {
	return func(_ int, sub realm) error {
		b := banker.NewBanker(banker.BankerTypeRealmSend, sub)
		b.SendCoins(sub.Address(), d.a.to, chain.NewCoins(chain.NewCoin(d.a.denom, d.a.amount)))
		return nil
	}
}

// ---- tier checks -----------------------------------------------------------

func inCouncil(dao *commondao.CommonDAO, a address) bool {
	set := dao.Council()
	found := false
	set.IterateByOffset(0, set.Size(), func(m address) bool {
		if m == a {
			found = true
			return true // stop
		}
		return false
	})
	return found
}

func isCore(a address) bool    { return inCouncil(coreDAO, a) }
func isSenator(a address) bool { return inCouncil(senateDAO, a) }

func assertCore(cur realm) {
	if !isCore(cur.Previous().Address()) {
		panic(errors.New("feles: core only"))
	}
}

// ---- read-only views (for the UI / render) ---------------------------------

func IsCore(a address) bool    { return isCore(a) }
func IsSenator(a address) bool { return isSenator(a) }
func IsMember(a address) bool  { return memberSet.Has(a) }

func Tier(a address) string {
	switch {
	case isCore(a):
		return "CORE"
	case isSenator(a):
		return "SENATE"
	case memberSet.Has(a):
		return "MEMBER"
	default:
		return "NONE"
	}
}

// ---- the custom proposal kind: MINT ---------------------------------------------
// Minting is CORE ONLY and has no senate equivalent. Spending the treasury is delegated
// authority; creating supply is not — a senate that can print is not a senate under a
// core, it is a second core. The hard cap lives in the token realm, so even Core cannot
// vote past MaxSupply.

type mintArgs struct {
	to     address
	amount int64
}

type mintKind struct{}

func (mintKind) Name() string { return "mint" }

func (mintKind) New(_ commondao.ReadonlyCommonDAO, args any) (commondao.ProposalDefinition, error) {
	a, ok := args.(mintArgs)
	if !ok {
		return nil, errors.New("feles: bad mint args")
	}
	if a.amount <= 0 {
		return nil, errors.New("feles: mint amount must be positive")
	}
	if !a.to.IsValid() {
		return nil, errors.New("feles: invalid recipient address")
	}
	// Refuse at proposal time what the token realm would refuse at execution time.
	if feles_token.Initialized() && a.amount > feles_token.Remaining() {
		return nil, errors.New("feles: mint would exceed max supply")
	}
	return mintDef{a}, nil
}

type mintDef struct{ a mintArgs }

func (mintDef) Title() string { return "Mint FELES" }

func (d mintDef) Body() string {
	return "Mint " + strconv.FormatInt(d.a.amount, 10) + " FELES to " + d.a.to.String()
}
func (mintDef) VotingPeriod() time.Duration    { return 7 * 24 * time.Hour }
func (mintDef) Threshold() commondao.Threshold { return commondao.ThresholdSupermajority }

func (d mintDef) Executor() commondao.ExecFunc {
	return func(_ int, sub realm) error {
		// This only works once the token's authority has been handed to THIS realm.
		feles_token.Mint(cross(sub), d.a.to, d.a.amount)
		return nil
	}
}

// ProposeMint opens a Core proposal to create supply. Core only.
func ProposeMint(cur realm, to address, amount int64) uint64 {
	assertCore(cur)
	caller := cur.Previous().Address()
	p, err := coreDAO.Propose(caller, "mint", mintArgs{to, amount})
	if err != nil {
		panic(err)
	}
	emitProposalOpened(p.ID(), "core", "mint", caller)
	return p.ID()
}

// MintAuthorityIsDAO reports whether the token is actually governed yet. Until the
// deployer hands authority over, a single key can still print supply.
func MintAuthorityIsDAO(cur realm) bool {
	return feles_token.Authority() == cur.Address()
}

// ---- the custom proposal kind: GRC20 spend ---------------------------------

type tokenSpendArgs struct {
	tokenKey string
	to       address
	amount   int64
}

type tokenSpendKind struct{}

func (tokenSpendKind) Name() string { return "treasury_token_spend" }

func (tokenSpendKind) New(_ commondao.ReadonlyCommonDAO, args any) (commondao.ProposalDefinition, error) {
	a, ok := args.(tokenSpendArgs)
	if !ok {
		return nil, errors.New("feles: bad treasury_token_spend args")
	}
	if a.amount <= 0 || a.tokenKey == "" {
		return nil, errors.New("feles: invalid token spend")
	}
	if !a.to.IsValid() {
		return nil, errors.New("feles: invalid recipient address")
	}
	// Fail at PROPOSAL time if the token is unknown, not at execution time after a
	// vote has already been held on something unspendable.
	if grc20reg.Get(a.tokenKey) == nil {
		return nil, errors.New("feles: unknown token " + a.tokenKey)
	}
	return tokenSpendDef{a}, nil
}

type tokenSpendDef struct{ a tokenSpendArgs }

func (tokenSpendDef) Title() string { return "Treasury token spend" }

func (d tokenSpendDef) Body() string {
	return "Send " + strconv.FormatInt(d.a.amount, 10) + " of " + d.a.tokenKey + " to " + d.a.to.String()
}
func (tokenSpendDef) VotingPeriod() time.Duration    { return 7 * 24 * time.Hour }
func (tokenSpendDef) Threshold() commondao.Threshold { return commondao.ThresholdSupermajority }

func (d tokenSpendDef) Executor() commondao.ExecFunc {
	return func(_ int, sub realm) error {
		tok := grc20reg.Get(d.a.tokenKey)
		if tok == nil {
			return errors.New("feles: token vanished from the registry: " + d.a.tokenKey)
		}
		// RealmTeller binds to sub's own address and asserts sub.IsCurrent(), so the
		// realm can only ever move its OWN balance.
		return tok.RealmTeller(0, sub).Transfer(0, sub, d.a.to, d.a.amount)
	}
}

// ---- events ----------------------------------------------------------------
// Nothing off chain can reconstruct governance from state alone: a roster is a
// snapshot, not a history, and a vote that was later superseded leaves no trace in
// it. Events are the only record an indexer or UI can follow, and they cannot be
// added to a realm after it is deployed — the path is immutable — so every action
// that changes authority, money or supply emits one.

func emitProposalOpened(id uint64, tier, kind string, by address) {
	chain.Emit("ProposalOpened",
		"id", strconv.FormatUint(id, 10),
		"tier", tier,
		"kind", kind,
		"by", by.String())
}

func emitVote(id uint64, tier string, voter address, choice commondao.VoteChoice) {
	chain.Emit("VoteCast",
		"id", strconv.FormatUint(id, 10),
		"tier", tier,
		"voter", voter.String(),
		"choice", string(choice))
}

// ---- the custom proposal kind: CORE ROSTER ---------------------------------
// Who holds final authority is itself a core decision, carried by the same
// supermajority as a treasury spend. See the note above AddSenator for why this
// is a proposal and the senate roster is not.

type coreRosterArgs struct {
	who address
	add bool
}

type coreRosterKind struct{}

func (coreRosterKind) Name() string { return "core_roster" }

func (coreRosterKind) New(_ commondao.ReadonlyCommonDAO, args any) (commondao.ProposalDefinition, error) {
	a, ok := args.(coreRosterArgs)
	if !ok {
		return nil, errors.New("feles: bad core_roster args")
	}
	if !a.who.IsValid() {
		return nil, errors.New("feles: invalid core address")
	}
	if a.add {
		if isCore(a.who) {
			return nil, errors.New("feles: already a core member")
		}
		return coreRosterDef{a}, nil
	}
	if !isCore(a.who) {
		return nil, errors.New("feles: not a core member")
	}
	// commondao refuses to empty a council, but it refuses at EXECUTION time — after
	// the vote has been held. Refuse here, where the answer is already knowable.
	if coreDAO.Council().Size() == 1 {
		return nil, errors.New("feles: cannot remove the last core member")
	}
	return coreRosterDef{a}, nil
}

type coreRosterDef struct{ a coreRosterArgs }

func (d coreRosterDef) Title() string {
	if d.a.add {
		return "Add core member"
	}
	return "Remove core member"
}

func (d coreRosterDef) Body() string                 { return d.a.who.String() }
func (coreRosterDef) VotingPeriod() time.Duration    { return 7 * 24 * time.Hour }
func (coreRosterDef) Threshold() commondao.Threshold { return commondao.ThresholdSupermajority }

func (d coreRosterDef) Executor() commondao.ExecFunc {
	return func(_ int, sub realm) error {
		var err error
		if d.a.add {
			err = coreDAO.UpdateCouncil([]address{d.a.who}, nil)
		} else {
			err = coreDAO.UpdateCouncil(nil, []address{d.a.who})
		}
		if err != nil {
			return err
		}
		chain.Emit("CoreRosterChanged",
			"who", d.a.who.String(),
			"added", strconv.FormatBool(d.a.add))
		return nil
	}
}

// ProposeAddCore opens a Core proposal to admit a new core member. Core only.
func ProposeAddCore(cur realm, who address) uint64 {
	return proposeCoreRoster(cur, who, true)
}

// ProposeRemoveCore opens a Core proposal to remove one. Core only — and no single
// core member can carry it: it needs the council's supermajority like any other.
func ProposeRemoveCore(cur realm, who address) uint64 {
	return proposeCoreRoster(cur, who, false)
}

func proposeCoreRoster(cur realm, who address, add bool) uint64 {
	assertCore(cur)
	caller := cur.Previous().Address()
	p, err := coreDAO.Propose(caller, "core_roster", coreRosterArgs{who, add})
	if err != nil {
		panic(err)
	}
	emitProposalOpened(p.ID(), "core", "core_roster", caller)
	return p.ID()
}

// ---- the custom proposal kind: TOKEN AUTHORITY HANDOVER --------------------------
// THE UPGRADE PATH. Package paths are immutable, so a DAO v2 lives at a new address
// and this realm can never become that one. The token is built for exactly that: mint
// authority is an address, not a hard-coded realm, so it can be handed forward.
//
// But the token guards TransferAuthority with assertAuthority, so once THIS realm
// holds authority, only THIS realm can pass it on — and it can only do so through
// code it already has. Without this kind, handing the token to the DAO would freeze
// its authority here permanently, orphaning the supply at the first upgrade: the
// precise failure the transferable-authority design exists to prevent.

type authorityArgs struct{ to address }

type authorityKind struct{}

func (authorityKind) Name() string { return "token_authority" }

func (authorityKind) New(_ commondao.ReadonlyCommonDAO, args any) (commondao.ProposalDefinition, error) {
	a, ok := args.(authorityArgs)
	if !ok {
		return nil, errors.New("feles: bad token_authority args")
	}
	if !a.to.IsValid() {
		return nil, errors.New("feles: invalid authority address")
	}
	return authorityDef{a}, nil
}

type authorityDef struct{ a authorityArgs }

func (authorityDef) Title() string { return "Transfer FELES mint authority" }

func (d authorityDef) Body() string {
	return "Hand mint authority to " + d.a.to.String() + " — this realm can never take it back"
}

func (authorityDef) VotingPeriod() time.Duration    { return 7 * 24 * time.Hour }
func (authorityDef) Threshold() commondao.Threshold { return commondao.ThresholdSupermajority }

func (d authorityDef) Executor() commondao.ExecFunc {
	return func(_ int, sub realm) error {
		feles_token.TransferAuthority(cross(sub), d.a.to)
		chain.Emit("TokenAuthorityTransferred", "to", d.a.to.String())
		return nil
	}
}

// ProposeAuthorityHandover opens a Core proposal to pass the token's mint authority
// on — normally to a successor realm. Core only, and IRREVERSIBLE once executed:
// the new holder is the only address that can move it again.
func ProposeAuthorityHandover(cur realm, to address) uint64 {
	assertCore(cur)
	if !feles_token.Initialized() {
		panic(errors.New("feles: token is not initialized"))
	}
	if feles_token.Authority() != cur.Address() {
		panic(errors.New("feles: this realm does not hold mint authority"))
	}
	if to == cur.Address() {
		panic(errors.New("feles: authority is already held here"))
	}
	caller := cur.Previous().Address()
	p, err := coreDAO.Propose(caller, "token_authority", authorityArgs{to})
	if err != nil {
		panic(err)
	}
	emitProposalOpened(p.ID(), "core", "token_authority", caller)
	return p.ID()
}

// ---- the custom proposal kind: BURN ---------------------------------------------
// The mirror of mint, and needed for the same reason: the token burns only from the
// authority's OWN balance, so once the DAO holds authority, FELES sitting in the
// treasury is unburnable unless the realm carries an entrypoint for it.

type burnArgs struct{ amount int64 }

type burnKind struct{}

func (burnKind) Name() string { return "burn" }

func (burnKind) New(_ commondao.ReadonlyCommonDAO, args any) (commondao.ProposalDefinition, error) {
	a, ok := args.(burnArgs)
	if !ok {
		return nil, errors.New("feles: bad burn args")
	}
	if a.amount <= 0 {
		return nil, errors.New("feles: burn amount must be positive")
	}
	return burnDef{a}, nil
}

type burnDef struct{ a burnArgs }

func (burnDef) Title() string { return "Burn FELES" }

func (d burnDef) Body() string {
	return "Destroy " + strconv.FormatInt(d.a.amount, 10) + " FELES held by the treasury"
}

func (burnDef) VotingPeriod() time.Duration    { return 7 * 24 * time.Hour }
func (burnDef) Threshold() commondao.Threshold { return commondao.ThresholdSupermajority }

func (d burnDef) Executor() commondao.ExecFunc {
	return func(_ int, sub realm) error {
		feles_token.Burn(cross(sub), d.a.amount)
		chain.Emit("TokensBurned", "amount", strconv.FormatInt(d.a.amount, 10))
		return nil
	}
}

// ProposeBurn opens a Core proposal to destroy treasury-held FELES. Core only.
func ProposeBurn(cur realm, amount int64) uint64 {
	assertCore(cur)
	if !feles_token.Initialized() {
		panic(errors.New("feles: token is not initialized"))
	}
	// Refuse at proposal time what the ledger would refuse after the vote.
	if amount > feles_token.BalanceOf(cur.Address()) {
		panic(errors.New("feles: treasury does not hold that much FELES"))
	}
	caller := cur.Previous().Address()
	p, err := coreDAO.Propose(caller, "burn", burnArgs{amount})
	if err != nil {
		panic(err)
	}
	emitProposalOpened(p.ID(), "core", "burn", caller)
	return p.ID()
}

// ---- treasury ---------------------------------------------------------------
// WHERE THE MONEY IS. Coins live at the REALM's own address, not at either DAO's:
// `commondao.New` without `WithAddress` leaves `dao.Address()` empty, and the executor
// spends from `sub.Address()`, which is this realm. So Core and Senate share ONE pot,
// with Core holding final say over it — which is the intended shape, but it is not
// obvious from the code, and funding the wrong address silently does nothing.
//
// Send coins here to fund the DAO.

func TreasuryAddress(cur realm) address { return cur.Address() }

func TreasuryTokenBalance(cur realm, tokenKey string) int64 {
	tok := grc20reg.Get(tokenKey)
	if tok == nil {
		panic(errors.New("feles: unknown token " + tokenKey))
	}
	return tok.BalanceOf(cur.Address())
}

func TreasuryBalance(cur realm) string {
	rb := banker.NewReadonlyBanker()
	return rb.GetCoins(cur.Address()).String()
}

// ---- render ----------------------------------------------------------------
// What gno.land shows for this realm. The tier roster is the governance state
// worth publishing: who holds authority is exactly what a member needs to check.

func Render(cur realm, path string) string {
	out := "# Feles DAO\n\n"
	out += "Three-tier authority governance. Within a tier, one address is one vote;\n"
	out += "authority comes from rank, not from any token balance.\n\n"

	out += "## Core — final authority\n\n"
	council := coreDAO.Council()
	council.IterateByOffset(0, council.Size(), func(a address) bool {
		out += "- " + a.String() + "\n"
		return false
	})

	out += "\n## Senate — delegated authority\n\n"
	if senateSuspended {
		out += "**SUSPENDED by Core.** The roster below holds no powers.\n\n"
	}
	sc := senateDAO.Council()
	if sc.Size() == 0 {
		out += "_No senators appointed._\n"
	}
	sc.IterateByOffset(0, sc.Size(), func(a address) bool {
		out += "- " + a.String() + "\n"
		return false
	})

	out += "\n## Treasury\n\n"
	out += "Address: " + cur.Address().String() + "\n\n"
	rb := banker.NewReadonlyBanker()
	if c := rb.GetCoins(cur.Address()); c.String() != "" {
		out += "- native: " + c.String() + "\n"
	} else {
		out += "_No native coins._\n"
	}
	out += "\nGRC20 holdings are per-token; query TreasuryTokenBalance(tokenKey).\n"

	out += "\n## Open proposals\n\n"
	out += "### Core\n\n" + renderActive(coreDAO, false)
	out += "\n### Senate\n\n" + renderActive(senateDAO, true)

	out += "\n## Members — propose and signal\n\n"
	if memberSet.Size() == 0 {
		out += "_No members yet._\n"
	}
	memberSet.IterateByOffset(0, memberSet.Size(), func(a address) bool {
		out += "- " + a.String() + "\n"
		return false
	})
	return out
}

// renderActive lists what is currently being voted on. Rosters and balances tell a
// member who holds power and what it controls; only this tells them what is being
// done with it right now — and before this existed, seeing a proposal at all meant
// already knowing its ID.
func renderActive(dao *commondao.CommonDAO, senate bool) string {
	n := dao.ActiveProposalsSize()
	if n == 0 {
		return "_None open._\n"
	}
	out := ""
	dao.IterateActiveProposals(0, n, false, func(p *commondao.Proposal) bool {
		d := p.Definition()
		rec := p.VotingRecord()
		out += "- **#" + strconv.FormatUint(p.ID(), 10) + " " + d.Title() + "** — " + d.Body() + "\n"
		out += "  - status: " + string(p.Status())
		// A vetoed senate proposal can still be PASSING. Saying so here is the point:
		// the veto is enforced at the execution gate, not in the tally.
		if senate && vetoed[p.ID()] {
			out += " — **VETOED by Core**; it cannot execute"
		}
		out += "\n"
		out += "  - votes: " + strconv.Itoa(rec.VoteCount(commondao.ChoiceYes)) + " yes, " +
			strconv.Itoa(rec.VoteCount(commondao.ChoiceNo)) + " no, " +
			strconv.Itoa(rec.VoteCount(commondao.ChoiceAbstain)) + " abstain\n"
		out += "  - opened by " + p.Creator().String() + "\n"
		out += "  - deadline: " + p.VotingDeadline().Format("2006-01-02 15:04:05 UTC") + "\n"
		return false
	})
	return out
}
