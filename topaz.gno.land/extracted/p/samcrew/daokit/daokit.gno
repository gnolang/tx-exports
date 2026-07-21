package daokit

import (
	"time"

	"gno.land/p/samcrew/daocond"
)

// Every entry point threads the DAO realm's own realm value.
//
// It serves two purposes. Execute forwards it to the action handlers, which
// cross out under it, so the implementation must refuse any realm that is not
// its own — otherwise a caller holding this handle could make the DAO act under
// the CALLER's identity. And because the realm is then known to be the DAO's,
// rlm.Previous() names the DAO's immediate caller, which a stack walk cannot do:
// reached through this handle there is no DAO realm frame on the stack at all,
// so a walk reports the signing account instead.
//
// An implementation must require the realm to be BOTH its own by pkgpath and
// current: every realm the DAO crosses out into receives the DAO's own realm as
// its cur.Previous() and can hand it back within the same transaction, and only
// IsCurrent() tells that apart from the live one.
//
// The realm is deliberately never the first parameter: a function whose first
// parameter is a realm is read as crossing, which /p/ packages may not declare.
type DAO interface {
	// Creates a new proposal and returns its ID.
	Propose(req ProposalRequest, rlm realm) uint64
	// Casts a vote on a specific proposal.
	Vote(id uint64, vote daocond.Vote, rlm realm)
	// Executes a proposal if it meets the required conditions.
	Execute(id uint64, rlm realm)

	// Generates a web interface representation for the given path.
	Render(path string) string

	// Gets an extension by path, returns nil if not found. A PRIVATE extension
	// additionally requires the DAO realm's own live realm, on the same terms
	// as the entry points above; a public one ignores it.
	Extension(path string, rlm realm) Extension
	// Lists all available extensions.
	ExtensionsList() ExtensionsList
}

// Function type for updating DAO implementation during governance upgrades.
type SetImplemFn = func(implem DAO)

// Creates, votes yes, and immediately executes a proposal in one operation.
// Useful when you have enough permission to execute an action directly.
// Examples: migrations, adding members.
//
// SAME REALM ONLY. Every step threads rlm, and each entry point requires it to
// be the receiving DAO's own — so d must be a DAO hosted by the realm calling
// this. Handing it a DAO belonging to another realm is refused.
//
// That refusal is the point. Driving a foreign DAO by passing it your realm is
// the donation shape: it makes the DAO act under YOUR identity, and it is what a
// caller holding the handle could previously do to any DAO. It appeared to work
// only because nothing checked.
//
// A parent DAO can still drive a child. Reach the child through the child
// REALM's own crossing function — child.Propose(cross(cur), req) — so the child
// mints its own realm and sees the parent as its caller. Make the parent a
// member of the child; the child then authorises it like any other member.
func InstantExecute(d DAO, req ProposalRequest, rlm realm) uint64 {
	id := d.Propose(req, rlm)
	d.Vote(id, daocond.VoteYes, rlm)
	d.Execute(id, rlm)
	return id
}

// Manages the essential components of a DAO: resources, proposals, and extensions.
type Core struct {
	Resources  *ResourcesStore  // Available actions and their conditions
	Proposals  *ProposalsStore  // All proposals and their voting state
	Extensions *ExtensionsStore // Pluggable functionality modules
}

// Creates a new DAO core with empty stores.
func NewCore() *Core {
	return &Core{
		Resources:  NewResourcesStore(),
		Proposals:  NewProposalsStore(),
		Extensions: &ExtensionsStore{},
	}
}

// Records a vote for a specific proposal from a voter.
func (d *Core) Vote(voterID string, proposalID uint64, vote daocond.Vote) {
	proposal := d.Proposals.GetProposal(proposalID)
	if proposal == nil {
		panic("proposal not found")
	}

	// Same terminal state as Execute: a ballot stays open right up until the
	// proposal executes, so support can still be withdrawn after the condition
	// is first met. Anything narrower would let a proposal be locked in.
	if proposal.Status == ProposalStatusExecuted {
		panic("proposal is already executed")
	}

	proposal.Ballot.Vote(voterID, vote)
}

// Executes a proposal if it meets the required voting conditions.
func (d *Core) Execute(proposalID uint64, rlm realm) {
	proposal := d.Proposals.GetProposal(proposalID)
	if proposal == nil {
		panic("proposal not found")
	}

	// Executed is the only status that disqualifies a proposal. It used to be
	// "anything but Open", which made the status a second, weaker gate on top of
	// the condition — and any realm holding the DAO handle could trip it by
	// rendering, since the read paths wrote Open -> Passed as they walked.
	// Whether a proposal may execute is decided by its condition, below, and
	// nothing else.
	if proposal.Status == ProposalStatusExecuted {
		panic("proposal is already executed")
	}

	if !proposal.Condition.Eval(proposal.Ballot) {
		panic("proposal condition is not met")
	}

	// Marked BEFORE the handler runs, not after. The handler crosses out of the
	// DAO, so a callee can re-enter here within the same transaction; marking
	// afterwards would let it execute the same proposal again. The old code was
	// protected from this only incidentally, by a "must be Open" test that also
	// made rendering able to brick a proposal.
	//
	// The cost is that Execute is NOT retry-safe. gno's recover() does not roll
	// back realm state, so a host realm that recovers around a failing Execute
	// keeps the marker and burns the proposal permanently. Do not recover around
	// it: let the transaction abort, which reverts the marker with everything
	// else. Marking afterwards would trade this for re-entrancy, which is worse.
	proposal.Status = ProposalStatusExecuted
	proposal.ExecutedAt = time.Now()

	d.Resources.Get(proposal.Action.Type()).Handler.Execute(proposal.Action, rlm)
}

// Creates a new proposal for voting and returns its ID.
func (d *Core) Propose(proposerID string, req ProposalRequest) uint64 {
	actionType := req.Action.Type()

	resource := d.Resources.Get(actionType)
	if resource == nil {
		panic("action type is not registered as a resource")
	}

	prop := d.Proposals.newProposal(proposerID, req, resource.Condition)
	return uint64(prop.ID)
}
