// Package sharedmembers is the Remix Lab reference shared membership
// service: one membership set that several apps consult.
//
// Other realms get read-only access through RoleOf, Size and Snapshot,
// which together implement core.MembershipReader (membership.read/v1).
// Mutations happen only through this realm's own authorized entry points;
// reading a member's role never grants the reader any power over that
// member.
package sharedmembers

import (
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/membership/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/policies/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/render/v1"
)

const (
	pkgPath  = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/sharedmembers"
	pageSize = 25

	// InterfaceVersion is the read interface this realm provides.
	InterfaceVersion = "membership.read/v1"
)

const (
	opInvite  = "members.invite"
	opRemove  = "members.remove"
	opSetRole = "members.set_role"
)

var (
	members *membership.Set
	policy  *policies.Policy
)

func init(cur realm) {
	deployer := cur.Previous()
	if deployer.IsUser() && deployer.Address().IsValid() {
		setup(deployer.Address())
	}
}

func setup(owner address) {
	members = membership.New(membership.Config{
		JoinMode:   membership.JoinInvitation,
		MaxMembers: 100,
	}, owner)
	policy = policies.New(members)
	policy.Define(opInvite, policies.RuleOwner, policies.RuleReviewer)
	policy.Define(opRemove, policies.RuleOwner, policies.RuleOwner)
	policy.Define(opSetRole, policies.RuleOwner, policies.RuleOwner)
}

// --- membership.read/v1 ---

// RoleOf returns addr's role.
func RoleOf(addr address) core.Role {
	if members == nil {
		return core.RoleNone
	}
	return members.RoleOf(addr)
}

// Size returns the number of members.
func Size() int {
	if members == nil {
		return 0
	}
	return members.Size()
}

// Snapshot returns members with at least minRole, or ok=false when more
// than max qualify or the service is not initialized. The returned slice is
// a fresh copy.
func Snapshot(minRole core.Role, max int) ([]address, bool) {
	if members == nil {
		return nil, false
	}
	return members.Snapshot(minRole, max)
}

// Members pages through members ordered by address.
func Members(offset, limit int) []core.MemberView {
	if members == nil {
		return nil
	}
	if limit < 1 || limit > pageSize {
		limit = pageSize
	}
	return members.List(offset, limit)
}

// --- Authorized mutations ---

// Invite lets addr join with role. Inviting a reviewer or owner also
// requires the set-role permission.
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
// reviewer or owner also requires the set-role permission.
func RevokeInvite(cur realm, addr address) {
	actor := authorize(cur, opInvite)
	if r, ok := members.InviteRole(addr); ok && r > core.RoleMember {
		must(policy.Authorize(opSetRole, actor))
	}
	must(members.RevokeInvite(addr))
}

// Invites pages through pending invitations ordered by address.
func Invites(offset, limit int) []core.MemberView {
	if members == nil {
		return nil
	}
	if limit < 1 || limit > pageSize {
		limit = pageSize
	}
	return members.Invites(offset, limit)
}

// Join accepts the caller's pending invitation.
func Join(cur realm) {
	ready()
	must(members.Join(cur.Previous().Address()))
}

// Leave removes the caller.
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

// Render lists the members.
func Render(path string) string {
	if members == nil {
		return render.Heading(1, "Shared membership") + "This service is not initialized.\n"
	}
	_, q := render.ParsePath(path)
	pages := render.PageCount(members.Size(), pageSize)
	page := render.Page(q, pages)
	var rows [][]string
	for _, m := range members.List((page-1)*pageSize, pageSize) {
		rows = append(rows, render.Row(m.Address.String(), m.Role.String()))
	}
	var sb strings.Builder
	sb.WriteString(render.Heading(1, "Shared membership"))
	sb.WriteString("Apps read this list through " + render.Code(InterfaceVersion) + ". ")
	sb.WriteString(strconv.Itoa(members.Size()) + " members.\n\n")
	sb.WriteString(render.Table([]string{"Address", "Role"}, rows))
	sb.WriteString(render.Pager(pkgPath, "", page, pages))
	return sb.String()
}

func authorize(cur realm, op string) address {
	ready()
	actor := cur.Previous().Address()
	must(policy.Authorize(op, actor))
	return actor
}

func ready() {
	if members == nil {
		panic(core.Errorf(core.ErrInvalidState, "service is not initialized").Error())
	}
}

func must(err error) {
	if err != nil {
		panic(err.Error())
	}
}
