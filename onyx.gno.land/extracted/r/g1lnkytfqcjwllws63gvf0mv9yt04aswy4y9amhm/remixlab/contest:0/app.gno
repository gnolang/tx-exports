// Package contest is a Remix Lab "demo-contest" app generated
// from a project configuration. Entrants submit through a fixed form,
// reviewers admit up to 10 entries, and members vote for a winner.
//
// The contest runs once: opening the vote closes submissions and review,
// freezes the admitted entries as the ballot's options and captures the
// current members as the electorate. Every submission is public chain
// data, including entries that are later rejected.
//
// Authority model: every write derives the actor from cur.Previous(), the
// immediate caller. An intermediary realm calling on a user's behalf acts as
// itself and gains none of that user's roles. Block state lives in
// unexported variables and only inert views leave the realm.
package contest

import (
	"strconv"
	"time"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/ballots/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/forms/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/membership/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/policies/v1"
)

const (
	pkgPath       = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/contest"
	appTitle      = "Demo contest"
	recipeID      = "demo-contest"
	recipeVersion = "1.0.0"
	pageSize      = 25
	maxEntries    = 10
	maxElectorate = 100
)

// titleIndex is the form field shown as each entry's title.
const titleIndex = 0

// Operation names checked against the policy.
const (
	opInvite  = "members.invite"
	opRemove  = "members.remove"
	opSetRole = "members.set_role"
	opSubmit  = "entry.submit"
	opReview  = "entry.review"
	opOpen    = "contest.open"
	opPolicy  = "policy.set"
)

var (
	members *membership.Set
	policy  *policies.Policy
	entries *forms.Form
	ballot  *ballots.Box

	// ballotID is 0 until voting opens; ballotEntries maps each ballot
	// option index to its entry ID.
	ballotID      uint64
	ballotEntries []uint64
)

// init captures the deployer as the first owner. A realm whose deployer is
// not a user stays uninitialized and rejects every write; there is no
// separate initialization call that someone else could front-run.
func init(cur realm) {
	deployer := cur.Previous()
	if deployer.IsUser() && deployer.Address().IsValid() {
		setup(deployer.Address())
	}
}

func setup(owner address) {
	members = membership.New(membership.Config{
		JoinMode:   membership.JoinInvitation,
		MaxMembers: maxElectorate,
	}, owner)

	policy = policies.New(members)
	policy.Define(opInvite, policies.RuleOwner, policies.RuleReviewer)
	policy.Define(opRemove, policies.RuleOwner, policies.RuleOwner)
	policy.Define(opSetRole, policies.RuleOwner, policies.RuleOwner)
	policy.Define(opSubmit, policies.RulePublic, policies.RulePublic)
	policy.Define(opReview, policies.RuleReviewer, policies.RuleReviewer)
	policy.Define(opOpen, policies.RuleOwner, policies.RuleReviewer)
	policy.Define(opPolicy, policies.RuleOwner, policies.RuleOwner)

	entries = forms.New(forms.Config{
		MaxSubmissions:  50,
		MaxPerSubmitter: 1,
		MaxPayloadBytes: 512,
	}, []forms.Field{
		{Name: "title", Label: "Demo title", Kind: forms.KindText, Required: true, MaxBytes: 80},
		{Name: "link", Label: "Where to see it", Kind: forms.KindText, Required: true, MaxBytes: 200},
		{Name: "team", Label: "Team", Kind: forms.KindText, Required: false, MaxBytes: 120},
	})

	ballot = ballots.NewBox(ballots.Config{
		MaxBallots:     1,
		MaxOptions:     maxEntries,
		MaxElectorate:  maxElectorate,
		QuorumPercent:  0,
		AllowAbstain:   false,
		MinDuration:    60,
		MaxDuration:    604800,
		MaxTitleBytes:  256,
		MaxOptionBytes: 102,
	})
	ballotID = 0
	ballotEntries = nil
}

// --- Entries ---

// Submit stores a contest entry for review and returns its ID. Every answer
// is public. Leave optional fields empty.
//   - title: required text, at most 80 bytes
//   - link: required text, at most 200 bytes
//   - team: optional text, at most 120 bytes
func Submit(cur realm, title string, link string, team string) uint64 {
	actor := authorize(cur, opSubmit)
	mustBeOpenForEntries()
	id, err := entries.Submit(actor, []string{title, link, team})
	must(err)
	return id
}

// Accept admits a submitted entry to the ballot. Decisions are final.
func Accept(cur realm, id uint64) {
	authorize(cur, opReview)
	mustBeOpenForEntries()
	if entries.CountByStatus(core.SubmissionAccepted) >= maxEntries {
		panic(core.Errorf(core.ErrLimitExceeded, "the contest already has "+strconv.Itoa(maxEntries)+" entries").Error())
	}
	must(entries.Review(id, core.SubmissionAccepted))
}

// Reject declines a submitted entry. Decisions are final.
func Reject(cur realm, id uint64) {
	authorize(cur, opReview)
	mustBeOpenForEntries()
	must(entries.Review(id, core.SubmissionRejected))
}

// --- Voting ---

// OpenVoting closes submissions and review, turns the admitted entries into
// the ballot's options, captures the current members as the electorate and
// opens voting for durationSeconds.
func OpenVoting(cur realm, durationSeconds int64) {
	actor := authorize(cur, opOpen)
	mustBeOpenForEntries()
	admitted := entries.Submissions(int(core.SubmissionAccepted), 0, maxEntries)
	if len(admitted) < 2 {
		panic(core.Errorf(core.ErrInvalidState, "at least two admitted entries are required").Error())
	}
	options := make([]string, len(admitted))
	ids := make([]uint64, len(admitted))
	for i, e := range admitted {
		ids[i] = e.ID
		options[i] = "#" + strconv.FormatUint(e.ID, 10) + " " + e.Answers[titleIndex]
	}
	id, err := ballot.Create(actor, appTitle, options, durationSeconds)
	must(err)
	electorate, ok := members.Snapshot(core.RoleMember, maxElectorate)
	if !ok {
		panic(core.Errorf(core.ErrLimitExceeded, "electorate too large").Error())
	}
	must(ballot.OpenWithElectorate(id, time.Now().Unix(), electorate))
	ballotID = id
	ballotEntries = ids
}

// Vote casts the caller's vote for an admitted entry.
func Vote(cur realm, entryID uint64) {
	ready()
	if ballotID == 0 {
		panic(core.Errorf(core.ErrInvalidState, "voting has not opened").Error())
	}
	choice := -1
	for i, id := range ballotEntries {
		if id == entryID {
			choice = i
		}
	}
	if choice < 0 {
		panic(core.Errorf(core.ErrNotFound, "entry is not on the ballot").Error())
	}
	must(ballot.Vote(ballotID, cur.Previous().Address(), choice, time.Now().Unix()))
}

// Finalize commits the result once the deadline has passed. Anyone may call
// it; the result depends only on rules frozen when voting opened.
func Finalize(cur realm) {
	ready()
	if ballotID == 0 {
		panic(core.Errorf(core.ErrInvalidState, "voting has not opened").Error())
	}
	_, err := ballot.Finalize(ballotID, time.Now().Unix())
	must(err)
}

// --- Membership ---

// Invite lets addr join with role. Inviting a reviewer or owner also
// requires the members.set_role permission.
func Invite(cur realm, addr address, role string) {
	actor := authorize(cur, opInvite)
	r, err := core.ParseRole(role)
	must(err)
	if r > core.RoleMember {
		must(policy.Authorize(opSetRole, actor))
	}
	must(members.Invite(addr, r))
}

// RevokeInvite cancels a pending invitation. Revoking an invitation for a
// reviewer or owner also requires the members.set_role permission.
func RevokeInvite(cur realm, addr address) {
	actor := authorize(cur, opInvite)
	if r, ok := members.InviteRole(addr); ok && r > core.RoleMember {
		must(policy.Authorize(opSetRole, actor))
	}
	must(members.RevokeInvite(addr))
}

// Join accepts the caller's pending invitation.
func Join(cur realm) {
	ready()
	must(members.Join(cur.Previous().Address()))
}

// Leave removes the caller from the membership. An open vote keeps its frozen
// electorate.
func Leave(cur realm) {
	ready()
	must(members.Leave(cur.Previous().Address()))
}

// RemoveMember removes addr.
func RemoveMember(cur realm, addr address) {
	authorize(cur, opRemove)
	must(members.Remove(addr))
}

// SetRole changes addr's role.
func SetRole(cur realm, addr address, role string) {
	authorize(cur, opSetRole)
	r, err := core.ParseRole(role)
	must(err)
	must(members.SetRole(addr, r))
}

// --- Policy ---

// SetRule changes the rule for an operation, within that operation's floor.
func SetRule(cur realm, op string, rule string) {
	authorize(cur, opPolicy)
	r, err := policies.ParseRule(rule)
	must(err)
	must(policy.Set(op, r))
}

// --- Reads ---

// Entry returns an inert copy of entry id in any status.
func Entry(id uint64) (core.SubmissionView, bool) {
	ready()
	return entries.Submission(id)
}

// Entries lists the admitted entries in submission order.
func Entries() []core.SubmissionView {
	ready()
	return entries.Submissions(int(core.SubmissionAccepted), 0, maxEntries)
}

// Queue pages through entries awaiting review in submission order.
func Queue(offset, limit int) []core.SubmissionView {
	ready()
	return entries.Submissions(int(core.SubmissionSubmitted), offset, clampLimit(limit))
}

// Fields returns a copy of the form schema.
func Fields() []forms.Field {
	ready()
	return entries.Fields()
}

// Ballot returns the contest ballot once voting has opened.
func Ballot() (core.BallotView, bool) {
	ready()
	if ballotID == 0 {
		return core.BallotView{}, false
	}
	return ballot.Ballot(ballotID)
}

// BallotEntries returns the entry ID of each ballot option, in option order.
func BallotEntries() []uint64 {
	ready()
	out := make([]uint64, len(ballotEntries))
	copy(out, ballotEntries)
	return out
}

// Winner returns the winning entry once the result is final and has a
// single winner.
func Winner() (uint64, bool) {
	ready()
	v, ok := Ballot()
	if !ok || v.Status != core.BallotFinalized || v.Outcome != core.OutcomeWinner {
		return 0, false
	}
	return ballotEntries[v.Winner], true
}

// HasVoted reports whether addr has voted.
func HasVoted(addr address) bool {
	ready()
	return ballotID != 0 && ballot.HasVoted(ballotID, addr)
}

// Members pages through members ordered by address.
func Members(offset, limit int) []core.MemberView {
	ready()
	return members.List(offset, clampLimit(limit))
}

// Invites returns up to limit pending invitations (at most 25) starting at
// offset, with the role each one grants.
func Invites(offset, limit int) []core.MemberView {
	ready()
	return members.Invites(offset, clampLimit(limit))
}

// RoleOf returns addr's role name.
func RoleOf(addr address) string {
	ready()
	return members.RoleOf(addr).String()
}

// Rules lists every operation's current rule.
func Rules() []policies.RuleView {
	ready()
	return policy.List()
}

// --- Internals ---

func authorize(cur realm, op string) address {
	ready()
	actor := cur.Previous().Address()
	must(policy.Authorize(op, actor))
	return actor
}

func mustBeOpenForEntries() {
	if ballotID != 0 {
		panic(core.Errorf(core.ErrInvalidState, "submissions are closed").Error())
	}
}

func ready() {
	if members == nil {
		panic(core.Errorf(core.ErrInvalidState, "app is not initialized").Error())
	}
}

func clampLimit(limit int) int {
	if limit < 1 || limit > pageSize {
		return pageSize
	}
	return limit
}

func must(err error) {
	if err != nil {
		panic(err.Error())
	}
}
