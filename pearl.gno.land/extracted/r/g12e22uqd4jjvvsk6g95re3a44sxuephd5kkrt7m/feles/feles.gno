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
	"time"

	"gno.land/p/g12e22uqd4jjvvsk6g95re3a44sxuephd5kkrt7m/addrset"
	"gno.land/p/g12e22uqd4jjvvsk6g95re3a44sxuephd5kkrt7m/commondao"
)

// ---- genesis CORE: the founding team --------------------------------------------
// These are the operator's own keys. Whoever holds them holds FINAL AUTHORITY over
// the realm, so they are the one thing to re-check before any redeploy.
//
// With a 2-member council, commondao's supermajority (3*yes >= 2*d) needs BOTH to
// vote yes on a core proposal. Adding a third founder relaxes that to 2 of 3.
var coreSeed = []address{
	"g12e22uqd4jjvvsk6g95re3a44sxuephd5kkrt7m", // Astake — deployer
	"g180zn65f9h588p6qnrh8gnjccgdt2mvpxnzy7us", // Bstake
	// Add the third founder on chain with AddCore once their address exists.
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
	)
}

// ---- tier membership -------------------------------------------------------
// Every tier change is a CORE action. Authority flows downward only.

func AddCore(cur realm, who address) {
	assertCore(cur)
	if err := coreDAO.UpdateCouncil([]address{who}, nil); err != nil {
		panic(err)
	}
}

func RemoveCore(cur realm, who address) {
	assertCore(cur)
	if err := coreDAO.UpdateCouncil(nil, []address{who}); err != nil {
		panic(err)
	}
}

func AddSenator(cur realm, who address) {
	assertCore(cur)
	if err := senateDAO.UpdateCouncil([]address{who}, nil); err != nil {
		panic(err)
	}
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
}

// ---- suspension: CORE disbands the senate's powers wholesale --------------------
// A suspended senate keeps its roster but can do nothing: no new proposals, no votes,
// no execution. This is the disband that ErrEmptyCouncil denies us structurally.

var senateSuspended bool

func SuspendSenate(cur realm) {
	assertCore(cur)
	senateSuspended = true
}

func ResumeSenate(cur realm) {
	assertCore(cur)
	senateSuspended = false
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
}

func RemoveMember(cur realm, who address) {
	assertCore(cur)
	memberSet.Remove(who)
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
}

func VoteCore(cur realm, proposalID uint64, choice commondao.VoteChoice, reason string) {
	caller := cur.Previous().Address()
	assertCore(cur)
	if err := coreDAO.Vote(caller, proposalID, choice, reason); err != nil {
		panic(err)
	}
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
}

func ExecuteCore(cur realm, proposalID uint64) {
	assertCore(cur)
	if err := coreDAO.Execute(proposalID, cur); err != nil {
		panic(err)
	}
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
}

// CORE can also lift its own veto.
func UnvetoSenateProposal(cur realm, proposalID uint64) {
	assertCore(cur)
	delete(vetoed, proposalID)
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
	return spendDef{a}, nil
}

type spendDef struct{ a spendArgs }

func (spendDef) Title() string                  { return "Treasury spend" }
func (spendDef) Body() string                   { return "Send coins from the Feles treasury" }
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

// ---- render ----------------------------------------------------------------
// What gno.land shows for this realm. The tier roster is the governance state
// worth publishing: who holds authority is exactly what a member needs to check.

func Render(path string) string {
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
