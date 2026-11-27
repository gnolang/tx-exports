package slotswitch

import (
	"chain/runtime"
	"sort"
	"strings"
	"time"
)

type pendingMember struct {
	member   address
	alias    string
	proposer address
}

type PendingMemberView struct {
	ID       int
	Member   address
	Alias    string
	Proposer address
}

// ProposeMember records one desk's approval of the exact wallet and alias.
func ProposeMember(cur realm, clinicID int, member address, alias string) int {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireAcceptedClinic(clinicID)
	if (caller != c.issuers[0] && caller != c.issuers[1]) || time.Now().Unix() >= c.endsAt {
		panic("issuer of an active clinic required")
	}
	if len(c.enrolled)+len(c.pendingMembers) >= maxMembers {
		panic("clinic enrollment capacity reached")
	}
	alias = validatedMemberAlias(c, member, alias)
	for _, pending := range c.pendingMembers {
		if pending.member == member || strings.EqualFold(pending.alias, alias) {
			panic("wallet or public alias already proposed")
		}
	}
	id := c.nextMemberProposalID
	c.nextMemberProposalID++
	c.pendingMembers[id] = pendingMember{member: member, alias: alias, proposer: caller}
	return id
}

// ApproveMember enrolls the proposed wallet only when the other desk confirms it.
func ApproveMember(cur realm, clinicID, proposalID int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireAcceptedClinic(clinicID)
	pending, exists := c.pendingMembers[proposalID]
	if !exists {
		panic("unknown member proposal")
	}
	if (caller != c.issuers[0] && caller != c.issuers[1]) || caller == pending.proposer {
		panic("other issuer must approve member")
	}
	if time.Now().Unix() >= c.endsAt {
		panic("clinic has ended")
	}
	alias := validatedMemberAlias(c, pending.member, pending.alias)
	insertMember(c, pending.member, alias)
	delete(c.pendingMembers, proposalID)
}

// WithdrawMember clears a pending proposal and releases its enrollment capacity.
func WithdrawMember(cur realm, clinicID, proposalID int) {
	runtime.AssertOriginCall()
	caller := signer(cur)
	c := requireAcceptedClinic(clinicID)
	pending, exists := c.pendingMembers[proposalID]
	if !exists || caller != pending.proposer {
		panic("member proposal owner required")
	}
	delete(c.pendingMembers, proposalID)
}

func PendingMembers(clinicID int) []PendingMemberView {
	c := requireClinic(clinicID)
	ids := make([]int, 0, len(c.pendingMembers))
	for id := range c.pendingMembers {
		ids = append(ids, id)
	}
	sort.Ints(ids)
	out := make([]PendingMemberView, 0, len(ids))
	for _, id := range ids {
		pending := c.pendingMembers[id]
		out = append(out, PendingMemberView{ID: id, Member: pending.member, Alias: pending.alias, Proposer: pending.proposer})
	}
	return out
}
