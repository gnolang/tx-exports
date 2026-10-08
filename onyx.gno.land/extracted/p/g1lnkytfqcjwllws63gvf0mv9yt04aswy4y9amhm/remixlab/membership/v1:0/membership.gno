// Package membership is the Remix Lab membership block: an address-based
// member set with owner/reviewer/member roles, invitation or open joining,
// and bounded listing.
//
// A host realm constructs a *Set, keeps it in an unexported variable and
// authenticates every mutation before calling it. The Set enforces its own
// invariants (limits, last-owner protection, join rules) but not who may
// administer it: that is the host's policy decision. Never export the *Set
// or return it from a realm function; any holder of the pointer can call its
// mutating methods with the host's storage authority.
//
// Membership is address-based. One address is not one human.
package membership

import (
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/nt/avl/v0"
)

// JoinMode controls how a non-member becomes a member through Join.
type JoinMode int

const (
	JoinInvitation JoinMode = iota // Join requires a pending invitation
	JoinOpen                       // anyone may Join
)

func (m JoinMode) String() string {
	if m == JoinOpen {
		return "open"
	}
	return "invitation"
}

// HardMaxMembers bounds MaxMembers regardless of configuration.
const HardMaxMembers = 1000

// Config is the block configuration, fixed at construction.
type Config struct {
	JoinMode   JoinMode
	MaxMembers int // includes owners and reviewers
}

// Validate checks configuration bounds.
func (c Config) Validate() error {
	if c.JoinMode != JoinInvitation && c.JoinMode != JoinOpen {
		return core.Errorf(core.ErrInvalidInput, "unknown join mode")
	}
	if c.MaxMembers < 1 || c.MaxMembers > HardMaxMembers {
		return core.Errorf(core.ErrInvalidInput, "maxMembers out of range")
	}
	return nil
}

// Set is a membership set. The zero value is not usable; call New.
type Set struct {
	cfg     Config
	members *avl.Tree // address string -> core.Role
	invites *avl.Tree // address string -> core.Role (role granted on Join)
	owners  int
}

// New creates a set whose first member is owner. It panics on invalid
// configuration or owner, since a host realm calls it from init.
func New(cfg Config, owner address) *Set {
	if err := cfg.Validate(); err != nil {
		panic(err.Error())
	}
	if !owner.IsValid() {
		panic(core.Errorf(core.ErrInvalidInput, "invalid owner address").Error())
	}
	s := &Set{cfg: cfg, members: avl.NewTree(), invites: avl.NewTree()}
	s.members.Set(owner.String(), core.RoleOwner)
	s.owners = 1
	return s
}

// Config returns the set's configuration.
func (s *Set) Config() Config { return s.cfg }

// RoleOf returns addr's role, RoleNone for non-members.
func (s *Set) RoleOf(addr address) core.Role {
	v := s.members.Get(addr.String())
	if v == nil {
		return core.RoleNone
	}
	return v.(core.Role)
}

// IsMember reports whether addr holds any role.
func (s *Set) IsMember(addr address) bool {
	return s.members.Has(addr.String())
}

// Size returns the number of members.
func (s *Set) Size() int { return s.members.Size() }

// Owners returns the number of owners.
func (s *Set) Owners() int { return s.owners }

// IsInvited reports whether addr holds a pending invitation.
func (s *Set) IsInvited(addr address) bool {
	return s.invites.Has(addr.String())
}

// PendingInvites returns the number of pending invitations.
func (s *Set) PendingInvites() int { return s.invites.Size() }

// InviteRole returns the role a pending invitation for addr grants.
func (s *Set) InviteRole(addr address) (core.Role, bool) {
	v := s.invites.Get(addr.String())
	if v == nil {
		return core.RoleNone, false
	}
	return v.(core.Role), true
}

// Invites returns up to limit pending invitations starting at offset,
// ordered by address, with the role each one grants.
func (s *Set) Invites(offset, limit int) []core.MemberView {
	var out []core.MemberView
	if offset < 0 || limit <= 0 {
		return out
	}
	s.invites.IterateByOffset(offset, limit, func(k string, v any) bool {
		out = append(out, core.MemberView{Address: address(k), Role: v.(core.Role)})
		return false
	})
	return out
}

// Snapshot implements core.MembershipReader. A negative max or an invalid
// minRole yields (nil, false).
func (s *Set) Snapshot(minRole core.Role, max int) ([]address, bool) {
	if max < 0 || !minRole.Valid() {
		return nil, false
	}
	var out []address
	ok := true
	s.members.Iterate("", "", func(k string, v any) bool {
		if v.(core.Role).AtLeast(minRole) {
			if len(out) == max {
				ok = false
				return true
			}
			out = append(out, address(k))
		}
		return false
	})
	if !ok {
		return nil, false
	}
	return out, true
}

// List returns up to limit members starting at offset, ordered by address.
func (s *Set) List(offset, limit int) []core.MemberView {
	var out []core.MemberView
	if offset < 0 || limit <= 0 {
		return out
	}
	s.members.IterateByOffset(offset, limit, func(k string, v any) bool {
		out = append(out, core.MemberView{Address: address(k), Role: v.(core.Role)})
		return false
	})
	return out
}

// Invite records a pending invitation granting role on Join. Only valid in
// invitation mode. Pending invitations count against MaxMembers so that
// accepting every invitation can never exceed the limit.
func (s *Set) Invite(addr address, role core.Role) error {
	if s.cfg.JoinMode != JoinInvitation {
		return core.Errorf(core.ErrInvalidState, "set uses open joining")
	}
	if err := checkGrantable(addr, role); err != nil {
		return err
	}
	if s.IsMember(addr) {
		return core.Errorf(core.ErrConflict, "already a member")
	}
	if s.IsInvited(addr) {
		return core.Errorf(core.ErrConflict, "already invited")
	}
	if err := s.checkCapacity(); err != nil {
		return err
	}
	s.invites.Set(addr.String(), role)
	return nil
}

// RevokeInvite removes a pending invitation.
func (s *Set) RevokeInvite(addr address) error {
	if _, removed := s.invites.Remove(addr.String()); !removed {
		return core.Errorf(core.ErrNotFound, "no pending invitation")
	}
	return nil
}

// Join adds actor as a member. actor must be the authenticated caller.
func (s *Set) Join(actor address) error {
	if s.IsMember(actor) {
		return core.Errorf(core.ErrConflict, "already a member")
	}
	role := core.RoleMember
	if s.cfg.JoinMode == JoinInvitation {
		v, removed := s.invites.Remove(actor.String())
		if !removed {
			return core.Errorf(core.ErrUnauthorized, "invitation required")
		}
		role = v.(core.Role)
	} else {
		if !actor.IsValid() {
			return core.Errorf(core.ErrInvalidInput, "invalid address")
		}
		if err := s.checkCapacity(); err != nil {
			return err
		}
	}
	s.members.Set(actor.String(), role)
	if role == core.RoleOwner {
		s.owners++
	}
	return nil
}

// Leave removes actor. actor must be the authenticated caller. The last
// owner cannot leave.
func (s *Set) Leave(actor address) error {
	return s.remove(actor)
}

// Add directly adds addr with role. The host must have authorized the actor.
func (s *Set) Add(addr address, role core.Role) error {
	if err := checkGrantable(addr, role); err != nil {
		return err
	}
	if s.IsMember(addr) {
		return core.Errorf(core.ErrConflict, "already a member")
	}
	// An invitation for the same address is superseded by the direct add.
	_, hadInvite := s.invites.Remove(addr.String())
	if !hadInvite {
		if err := s.checkCapacity(); err != nil {
			return err
		}
	}
	s.members.Set(addr.String(), role)
	if role == core.RoleOwner {
		s.owners++
	}
	return nil
}

// Remove removes addr. The host must have authorized the actor. The last
// owner cannot be removed.
func (s *Set) Remove(addr address) error {
	return s.remove(addr)
}

// SetRole changes an existing member's role. Demoting the last owner fails.
func (s *Set) SetRole(addr address, role core.Role) error {
	if err := checkGrantable(addr, role); err != nil {
		return err
	}
	cur := s.RoleOf(addr)
	if cur == core.RoleNone {
		return core.Errorf(core.ErrNotFound, "not a member")
	}
	if cur == role {
		return nil
	}
	if cur == core.RoleOwner && s.owners == 1 {
		return core.Errorf(core.ErrInvalidState, "cannot demote the last owner")
	}
	if cur == core.RoleOwner {
		s.owners--
	}
	if role == core.RoleOwner {
		s.owners++
	}
	s.members.Set(addr.String(), role)
	return nil
}

func (s *Set) remove(addr address) error {
	cur := s.RoleOf(addr)
	if cur == core.RoleNone {
		return core.Errorf(core.ErrNotFound, "not a member")
	}
	if cur == core.RoleOwner {
		if s.owners == 1 {
			return core.Errorf(core.ErrInvalidState, "cannot remove the last owner")
		}
		s.owners--
	}
	s.members.Remove(addr.String())
	return nil
}

func (s *Set) checkCapacity() error {
	if s.members.Size()+s.invites.Size() >= s.cfg.MaxMembers {
		return core.Errorf(core.ErrLimitExceeded, "membership is full")
	}
	return nil
}

func checkGrantable(addr address, role core.Role) error {
	if !addr.IsValid() {
		return core.Errorf(core.ErrInvalidInput, "invalid address")
	}
	if role == core.RoleNone || !role.Valid() {
		return core.Errorf(core.ErrInvalidInput, "invalid role")
	}
	return nil
}
