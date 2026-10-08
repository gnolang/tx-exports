// Package directory is a Remix Lab "community-directory" app generated
// from a project configuration. Entries are submitted through a fixed form;
// reviewers accept or reject them, and accepted entries are listed publicly.
//
// Every submission is public chain data, including entries that are later
// rejected. Rejected entries are not shown on the rendered pages.
//
// Authority model: every write derives the actor from cur.Previous(), the
// immediate caller. An intermediary realm calling on a user's behalf acts as
// itself and gains none of that user's roles. Block state lives in
// unexported variables and only inert views leave the realm.
package directory

import (
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/forms/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/membership/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/policies/v1"
)

const (
	pkgPath       = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/directory"
	appTitle      = "Community directory"
	recipeID      = "community-directory"
	recipeVersion = "1.0.0"
	pageSize      = 25
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
	opPolicy  = "policy.set"
)

var (
	members *membership.Set
	policy  *policies.Policy
	entries *forms.Form
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
		MaxMembers: 50,
	}, owner)

	policy = policies.New(members)
	policy.Define(opInvite, policies.RuleOwner, policies.RuleReviewer)
	policy.Define(opRemove, policies.RuleOwner, policies.RuleOwner)
	policy.Define(opSetRole, policies.RuleOwner, policies.RuleOwner)
	policy.Define(opSubmit, policies.RulePublic, policies.RulePublic)
	policy.Define(opReview, policies.RuleReviewer, policies.RuleReviewer)
	policy.Define(opPolicy, policies.RuleOwner, policies.RuleOwner)

	entries = forms.New(forms.Config{
		MaxSubmissions:  100,
		MaxPerSubmitter: 3,
		MaxPayloadBytes: 1024,
	}, []forms.Field{
		{Name: "name", Label: "Project name", Kind: forms.KindText, Required: true, MaxBytes: 80},
		{Name: "link", Label: "Realm or repository", Kind: forms.KindText, Required: true, MaxBytes: 200},
		{Name: "category", Label: "Category", Kind: forms.KindChoice, Required: true, Choices: []string{"Realm", "Library", "Tool", "Other"}},
		{Name: "since", Label: "Year started", Kind: forms.KindInteger, Required: false, Min: 2000, Max: 2100},
		{Name: "summary", Label: "Summary", Kind: forms.KindText, Required: false, MaxBytes: 500, Multiline: true},
	})
}

// --- Entries ---

// Submit stores an entry for review and returns its ID. Every answer is
// public. Leave optional fields empty.
//   - name: required text, at most 80 bytes
//   - link: required text, at most 200 bytes
//   - category: required, one of the field's 4 choices
//   - since: optional integer from 2000 to 2100
//   - summary: optional multi-line text, at most 500 bytes
func Submit(cur realm, name string, link string, category string, since string, summary string) uint64 {
	actor := authorize(cur, opSubmit)
	id, err := entries.Submit(actor, []string{name, link, category, since, summary})
	must(err)
	return id
}

// Accept lists a submitted entry publicly. Review decisions are final.
func Accept(cur realm, id uint64) {
	authorize(cur, opReview)
	must(entries.Review(id, core.SubmissionAccepted))
}

// Reject declines a submitted entry. Review decisions are final.
func Reject(cur realm, id uint64) {
	authorize(cur, opReview)
	must(entries.Review(id, core.SubmissionRejected))
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

// Leave removes the caller from the membership.
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

// Entries pages through accepted entries in submission order.
func Entries(offset, limit int) []core.SubmissionView {
	ready()
	return entries.Submissions(int(core.SubmissionAccepted), offset, clampLimit(limit))
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
