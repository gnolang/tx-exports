// Package sharedpoll is the Remix Lab shared-membership composition demo: a
// poll app whose electorate comes from an existing shared membership realm
// instead of its own member list.
//
// The shared realm is consulted read-only, when a poll opens, to snapshot
// its members. People join or leave through the shared realm's own
// interface. This app's administrators (who may create and open polls) are
// a separate, local set seeded with the deployer.
package sharedpoll

import (
	"strings"
	"time"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/ballots/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/membership/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/policies/v1"
)

const (
	pkgPath       = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/sharedpoll"
	recipeID      = "shared-poll-demo"
	recipeVersion = "1.0.0"
	pageSize      = 25
	optionSep     = "|"
	configDigest  = "unset"
)

const (
	opAdmins = "admins.manage"
	opCreate = "poll.create"
	opOpen   = "poll.open"
	opPolicy = "policy.set"
)

var (
	admins *membership.Set
	policy *policies.Policy
	polls  *ballots.Box
)

func init(cur realm) {
	deployer := cur.Previous()
	if deployer.IsUser() && deployer.Address().IsValid() {
		setup(deployer.Address())
	}
}

func setup(owner address) {
	admins = membership.New(membership.Config{
		JoinMode:   membership.JoinInvitation,
		MaxMembers: 10,
	}, owner)
	policy = policies.New(admins)
	policy.Define(opAdmins, policies.RuleOwner, policies.RuleOwner)
	policy.Define(opCreate, policies.RuleOwner, policies.RuleReviewer)
	policy.Define(opOpen, policies.RuleOwner, policies.RuleReviewer)
	policy.Define(opPolicy, policies.RuleOwner, policies.RuleOwner)
	polls = ballots.NewBox(ballots.Config{
		MaxBallots:     100,
		MaxOptions:     20,
		MaxElectorate:  100,
		QuorumPercent:  0,
		AllowAbstain:   false,
		MinDuration:    60,
		MaxDuration:    2592000,
		MaxTitleBytes:  140,
		MaxOptionBytes: 80,
	})
}

// Descriptor identifies this app's recipe, components and bindings.
func Descriptor() core.AppDescriptor {
	return core.AppDescriptor{
		Recipe:        recipeID,
		RecipeVersion: recipeVersion,
		Components: []string{
			"ballots@1.0.0",
			"core@1.0.0",
			"membership@1.0.0",
			"policies@1.0.0",
			"render@1.0.0",
			"shared-membership@1.0.0",
		},
		ConfigDigest:      configDigest,
		ViewSchemaVersion: core.ViewSchemaVersion,
		Bindings:          []string{"membership.read/v1=" + sharedPath},
	}
}

// AddAdmin grants addr a local administrative role ("reviewer" or "owner").
func AddAdmin(cur realm, addr address, role string) {
	authorize(cur, opAdmins)
	r, err := core.ParseRole(role)
	must(err)
	if r != core.RoleReviewer && r != core.RoleOwner {
		panic(core.Errorf(core.ErrInvalidInput, "admins are reviewers or owners").Error())
	}
	must(admins.Add(addr, r))
}

// RemoveAdmin removes a local administrator.
func RemoveAdmin(cur realm, addr address) {
	authorize(cur, opAdmins)
	must(admins.Remove(addr))
}

// CreatePoll creates a draft poll. options are separated by "|".
func CreatePoll(cur realm, title string, options string, durationSeconds int64) uint64 {
	actor := authorize(cur, opCreate)
	id, err := polls.Create(actor, title, strings.Split(options, optionSep), durationSeconds)
	must(err)
	return id
}

// CancelPoll deletes a draft poll that was never opened. The poll's creator
// may cancel it, and so may anyone allowed to open polls.
func CancelPoll(cur realm, id uint64) {
	ready()
	actor := cur.Previous().Address()
	if creator, ok := polls.Creator(id); ok && creator == actor {
		must(policy.Authorize(opCreate, actor))
	} else {
		must(policy.Authorize(opOpen, actor))
	}
	must(polls.CancelDraft(id))
}

// OpenPoll snapshots the shared realm's current members as the electorate.
func OpenPoll(cur realm, id uint64) {
	authorize(cur, opOpen)
	voters, ok := electorate.Snapshot(core.RoleMember, polls.Config().MaxElectorate)
	if !ok {
		panic(core.Errorf(core.ErrLimitExceeded, "electorate too large").Error())
	}
	must(polls.OpenWithElectorate(id, time.Now().Unix(), voters))
}

// Vote casts the caller's vote for option index choice.
func Vote(cur realm, id uint64, choice int) {
	ready()
	must(polls.Vote(id, cur.Previous().Address(), choice, time.Now().Unix()))
}

// Finalize commits a poll's result once its deadline has passed.
func Finalize(cur realm, id uint64) {
	ready()
	_, err := polls.Finalize(id, time.Now().Unix())
	must(err)
}

// SetRule changes the rule for an operation, within its floor.
func SetRule(cur realm, op string, rule string) {
	authorize(cur, opPolicy)
	r, err := policies.ParseRule(rule)
	must(err)
	must(policy.Set(op, r))
}

// Poll returns an inert summary of poll id.
func Poll(id uint64) (core.BallotView, bool) {
	ready()
	return polls.Ballot(id)
}

// Polls pages through polls, newest first.
func Polls(offset, limit int) []core.BallotView {
	ready()
	if limit < 1 || limit > pageSize {
		limit = pageSize
	}
	return polls.List(offset, limit)
}

// AdminRole returns addr's local administrative role name ("none" when
// addr is not an administrator).
func AdminRole(addr address) string {
	ready()
	return admins.RoleOf(addr).String()
}

// HasVoted reports whether addr voted in poll id.
func HasVoted(id uint64, addr address) bool {
	ready()
	return polls.HasVoted(id, addr)
}

func authorize(cur realm, op string) address {
	ready()
	actor := cur.Previous().Address()
	must(policy.Authorize(op, actor))
	return actor
}

func ready() {
	if admins == nil {
		panic(core.Errorf(core.ErrInvalidState, "app is not initialized").Error())
	}
}

func must(err error) {
	if err != nil {
		panic(err.Error())
	}
}
