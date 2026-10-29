package memba_dao

// Executed ACL coverage (migration plan — memba_dao guarded paths).
//
// The pre-existing tests (memba_dao_test.gno) only inspect init() state and
// Render output, so the membership guard on the governance path was never
// executed. These tests drive each guarded crossing fn via
// testing.SetRealm(testing.NewUserRealm(addr)) + Fn(cross, …): the founding
// member succeeds, a stranger aborts.
//
// Guard under test (gnodaokit basedao): Propose / Vote / Execute each call
// DAOPrivate.assertCallerIsMember(), which panics with
// errors.New("caller is not a member") when realmid.Previous() (the default
// CallerID) is not a registered member. A panic inside a crossing call
// surfaces as an abort, so we assert with uassert.AbortsWithMessage; the
// abort value is the error, rendered by ufmt "%v" to its plain message.
//
// founderAddr is the single founding member seeded by init() (admin+dev).
// With one member and a 66% members-threshold, that member alone can carry a
// proposal: Propose, Vote yes (1/1 = 100% ≥ 66%), then Execute. Each test
// cleans up the proposals/members it creates so state does not leak across
// tests (proposal IDs are monotonic via seqid and never reused).
//
// RUNNING: memba_dao is gnodaokit-coupled, so `gno test` from this dir alone
// fails to resolve its deps. It needs gnodaokit's `/v0` deploy form (branch
// `test12-deploy`, whose p/nt imports are /v0-suffixed to match the toolchain —
// gnodaokit `main` is unsuffixed and will NOT resolve) plus the `_deps`
// vendor, staged into $GNOROOT/examples. Verified green (9 tests, gno
// chain/test12 build): stage p/samcrew/{basedao,daokit,daocond,realmid} from
// gnodaokit test12-deploy + the deployer's _deps/{demo/profile,onbloc/json,
// onbloc/uint256} + this realm into examples, then `gno test`. CI keeps
// memba_dao INFORMATIONAL until that workspace is wired into the gate.

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/samcrew/basedao"
	"gno.land/p/samcrew/daocond"
	"gno.land/p/samcrew/daokit"
)

const callerNotMember = "caller is not a member"

var (
	aclFounder  = address("g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0") // seeded member (admin+dev)
	aclStranger = testutils.TestAddress("dao_stranger")              // never a member
	aclNewbie   = testutils.TestAddress("dao_newbie")                // throwaway add/remove target
)

// aclAddMemberRequest builds a valid, registered governance request
// (the AddMember resource is registered by basedao.New with the DAO's
// initial 66% condition).
func aclAddMemberRequest(addr address) daokit.ProposalRequest {
	return daokit.ProposalRequest{
		Title:       "acl-test add member",
		Description: "ephemeral proposal created by ACL tests",
		Action: basedao.NewAddMemberAction(&basedao.ActionAddMember{
			Address: addr,
			Roles:   []string{"member"},
		}),
	}
}

// aclLatestProposalKey returns the avl key of the most recently created
// proposal. Propose discards its return value and ids are monotonic, so the
// newest proposal is the one with the largest id; we track both the key (for
// removal, avoiding a seqid import) and the id (for Vote/Execute calls).
func aclLatestProposalKey() (key string, id uint64) {
	daoPrivate.Core.Proposals.Tree.Iterate("", "", func(k string, value any) bool {
		p := value.(*daokit.Proposal)
		if uint64(p.ID) >= id {
			key, id = k, uint64(p.ID)
		}
		return false
	})
	return key, id
}

func aclProposalCount() int {
	return daoPrivate.Core.Proposals.Tree.Size()
}

// ── Propose (members only) ──────────────────────────────────

func TestACL_Propose_MemberSucceeds(cur realm, t *testing.T) {
	before := aclProposalCount()

	testing.SetRealm(testing.NewUserRealm(aclFounder))
	Propose(cross, aclAddMemberRequest(aclNewbie))

	uassert.Equal(t, before+1, aclProposalCount(), "member Propose should create a proposal")

	// cleanup: drop the proposal row we just created
	key, _ := aclLatestProposalKey()
	daoPrivate.Core.Proposals.Tree.Remove(key)
	uassert.Equal(t, before, aclProposalCount(), "test must leave proposal store as it found it")
}

func TestACL_Propose_StrangerAborts(cur realm, t *testing.T) {
	before := aclProposalCount()

	testing.SetRealm(testing.NewUserRealm(aclStranger))
	uassert.AbortsWithMessage(t, callerNotMember, func() {
		Propose(cross, aclAddMemberRequest(aclNewbie))
	})

	uassert.Equal(t, before, aclProposalCount(), "rejected Propose must not create a proposal")
}

// ── Vote (members only) ─────────────────────────────────────

func TestACL_Vote_StrangerAborts(cur realm, t *testing.T) {
	// Seed a real open proposal as the founder so the abort comes from the
	// member guard, not from "proposal not found".
	testing.SetRealm(testing.NewUserRealm(aclFounder))
	Propose(cross, aclAddMemberRequest(aclNewbie))
	key, id := aclLatestProposalKey()
	defer daoPrivate.Core.Proposals.Tree.Remove(key)

	testing.SetRealm(testing.NewUserRealm(aclStranger))
	uassert.AbortsWithMessage(t, callerNotMember, func() {
		Vote(cross, id, daocond.VoteYes)
	})
}

// ── Execute (members only) ──────────────────────────────────

func TestACL_Execute_StrangerAborts(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(aclFounder))
	Propose(cross, aclAddMemberRequest(aclNewbie))
	key, id := aclLatestProposalKey()
	defer daoPrivate.Core.Proposals.Tree.Remove(key)

	testing.SetRealm(testing.NewUserRealm(aclStranger))
	uassert.AbortsWithMessage(t, callerNotMember, func() {
		Execute(cross, id)
	})
}

// ── Full member lifecycle: Propose → Vote → Execute ─────────

// With a single member and a 66% threshold, the founder alone can carry a
// proposal end-to-end. This exercises the authorized path through all three
// guarded fns and proves the guard does not block legitimate governance.
func TestACL_MemberLifecycle_Succeeds(cur realm, t *testing.T) {
	uassert.False(t, daoPrivate.Members.IsMember(aclNewbie.String()),
		"precondition: newbie must not already be a member")

	testing.SetRealm(testing.NewUserRealm(aclFounder))
	Propose(cross, aclAddMemberRequest(aclNewbie))
	key, id := aclLatestProposalKey()

	Vote(cross, id, daocond.VoteYes)
	Execute(cross, id)

	uassert.True(t, daoPrivate.Members.IsMember(aclNewbie.String()),
		"founder-carried AddMember proposal should add the new member")

	// cleanup: remove the newbie and drop the executed proposal row so the
	// member set + proposal store return to their seeded state.
	daoPrivate.Members.RemoveMember(aclNewbie.String())
	daoPrivate.Core.Proposals.Tree.Remove(key)

	uassert.False(t, daoPrivate.Members.IsMember(aclNewbie.String()),
		"test must leave the founder as the only member")
}
