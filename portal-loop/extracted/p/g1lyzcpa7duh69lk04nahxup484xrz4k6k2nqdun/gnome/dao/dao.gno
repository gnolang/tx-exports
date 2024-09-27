package dao

import (
	"errors"
	"std"
	"strings"
	"time"
)

// PathSeparator defines the DAO path separator.
const PathSeparator = "/"

type (
	// Role defines the type for DAO roles.
	Role string

	// Roles defines the type for a list of DAO roles.
	Roles []Role
)

// String returns the role as a string.
func (r Role) String() string {
	return string(r)
}

// NewMember creates a new DAO member.
func NewMember(addr std.Address, roles ...Role) Member {
	return Member{
		Address: addr,
		Roles:   roles,
	}
}

// Member defines a DAO member.
type Member struct {
	// Address is the member account address.
	Address std.Address

	// Roles contains the optional list of roles that the member belongs to.
	Roles Roles
}

// String returns a string representation of the member.
func (m Member) String() string {
	if len(m.Roles) == 0 {
		return m.Address.String()
	}

	var roles []string
	for _, r := range m.Roles {
		roles = append(roles, string(r))
	}
	return m.Address.String() + " " + strings.Join(roles, ", ")
}

// HasRole checks if the member belongs to a specific role.
func (m Member) HasRole(r Role) bool {
	for _, role := range m.Roles {
		if role == r {
			return true
		}
	}
	return false
}

// Option configures DAO.
type Option func(*DAO)

// AssignAsSuperCouncil makes the DAO a super council.
func AssignAsSuperCouncil() Option {
	return func(dao *DAO) {
		dao.isSuperCouncil = true
	}
}

// WithSubDAO assigns sub DAO to a DAO.
func WithSubDAO(sub *DAO) Option {
	return func(dao *DAO) {
		sub.parent = dao
		dao.children = append(dao.children, sub)
	}
}

// WithMembers assigns members to a DAO.
func WithMembers(members ...Member) Option {
	return func(dao *DAO) {
		dao.members = members
	}
}

// WithManifest assigns a manifest to a DAO.
// Manifest should describe the purpose of the DAO.
func WithManifest(manifest string) Option {
	return func(dao *DAO) {
		dao.manifest = manifest
	}
}

// New creates a new DAO.
func New(name, title string, options ...Option) (*DAO, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errors.New("DAO name is required")
	}

	if !IsSlug(name) {
		return nil, errors.New(`DAO name is not valid, only letters from "a" to "z", numbers, "-" and "_" are allowed`)
	}

	title = strings.TrimSpace(title)
	if title == "" {
		return nil, errors.New("DAO title is required")
	}

	dao := &DAO{
		name:      name,
		title:     title,
		createdAt: time.Now(),
	}

	for _, apply := range options {
		apply(dao)
	}

	return dao, nil
}

// MustNew creates a new DAO.
// The function panics if any of the arguments is not valid.
func MustNew(name, title string, options ...Option) *DAO {
	dao, err := New(name, title, options...)
	if err != nil {
		panic(err)
	}
	return dao
}

// DAO is a decentralized autonomous organization.
type DAO struct {
	name           string
	title          string
	manifest       string
	isSuperCouncil bool
	isLocked       bool
	lockReason     string
	parent         *DAO
	children       []*DAO
	members        []Member
	createdAt      time.Time
}

// Name returns the name of the DAO.
func (dao DAO) Name() string {
	return dao.name
}

// Title returns the title of the DAO.
func (dao DAO) Title() string {
	return dao.title
}

// Manifest returns the manifest of the DAO.
func (dao DAO) Manifest() string {
	return dao.manifest
}

// SetManifest sets the manifest of the DAO.
func (dao *DAO) SetManifest(s string) {
	dao.manifest = s
}

// CreatedAt returns the creation time of the DAO.
func (dao DAO) CreatedAt() time.Time {
	return dao.createdAt
}

// Parent returns the parent DAO of the sub DAO.
// The result is nil for the DAO at the root of the DAO tree.
func (dao DAO) Parent() *DAO {
	return dao.parent
}

// Path returns the path of the DAO.
func (dao DAO) Path() string {
	if dao.parent == nil {
		return dao.name
	}
	return dao.parent.Path() + PathSeparator + dao.name
}

// SubDAOs returns the first level sub DAOs.
func (dao DAO) SubDAOs() []*DAO { // TODO: Use Children() instead? Find a better name.
	return dao.children
}

// GetFirstSubDAO returns the first sub DAO.
func (dao DAO) GetFirstSubDAO() *DAO {
	if len(dao.children) > 0 {
		return dao.children[0]
	}
	return nil
}

// CollectSubDAOs collects all sub DAOs.
func (dao DAO) CollectSubDAOs() []*DAO {
	res := append([]*DAO{}, dao.children...)
	for _, c := range dao.children {
		res = append(res, c.CollectSubDAOs()...)
	}
	return res
}

// Members returns the members of the DAOs.
func (dao DAO) Members() []Member {
	return dao.members
}

// LockReason returns a string with the reason the DAO is locked.
func (dao DAO) LockReason() string {
	return dao.lockReason
}

// IsSuperCouncil checks if the DAO is a super council.
func (dao DAO) IsSuperCouncil() bool {
	return dao.isSuperCouncil
}

// IsLocked checks if the DAO is locked.
func (dao DAO) IsLocked() bool {
	return dao.isLocked
}

// Lock locks the DAO.
func (dao *DAO) Lock(reason string) {
	dao.lockReason = reason
	dao.isLocked = true
}

// HasParent checks if a DAO is a parent of this DAO.
func (dao DAO) HasParent(parent *DAO) bool {
	if parent == nil {
		return false
	}
	return strings.HasPrefix(dao.Path(), parent.Path())
}

// HasMember checks if a member is part of the DAO.
func (dao DAO) HasMember(addr std.Address) bool {
	for _, m := range dao.members {
		if m.Address == addr {
			return true
		}
	}
	return false
}

// AddMember adds a member to the DAO.
// Caller must check the member before adding to avoid duplications.
func (dao *DAO) AddMember(m Member) {
	dao.members = append(dao.members, m)
}

// GetMember gets a member of the DAO.
func (dao DAO) GetMember(addr std.Address) (Member, bool) {
	for _, m := range dao.members {
		if m.Address == addr {
			return m, true
		}
	}
	return Member{}, false
}

// RemoveMember removes a member of the DAO.
func (dao *DAO) RemoveMember(addr std.Address) bool {
	for i, m := range dao.members {
		if m.Address == addr {
			dao.members = append(dao.members[:i], dao.members[i+1:]...)
			return true
		}
	}
	return false
}

// AddSubDAO adds a sub DAO to the DAO.
func (dao *DAO) AddSubDAO(sub *DAO) bool {
	if sub == nil {
		return false
	}

	for _, n := range dao.children {
		if n.name == sub.name {
			return false
		}
	}

	sub.parent = dao
	dao.children = append(dao.children, sub)
	return true
}

// GetDAO get a DAO by path.
func (dao *DAO) GetDAO(path string) *DAO {
	if path == "" {
		return nil
	}

	if path == dao.name {
		return dao
	}

	// Make sure that current node is not present at the beginning of the path
	path = strings.TrimPrefix(path, dao.name+PathSeparator)

	// Split DAO path in child name and relative sub path
	parts := strings.SplitN(path, PathSeparator, 2)
	childName := parts[0]

	for _, sub := range dao.children {
		if sub.name != childName {
			continue
		}

		if len(parts) > 1 {
			// Traverse node children when a sub node path is available
			return sub.GetDAO(parts[1])
		}
		return sub
	}

	return nil
}

// RemoveSubDAO removes a sub DAO.
// The sub DAO must be a first level children of the DAO.
func (dao *DAO) RemoveSubDAO(name string) bool {
	for i, sub := range dao.children {
		if sub.name == name {
			dao.children = append(dao.children[:i], dao.children[i+1:]...)
			return true
		}
	}
	return false
}

// IsRoot checks if the DAO is the main DAO.
// The main DAO is the root of the DAO tree.
func (dao DAO) IsRoot() bool {
	return dao.parent == nil
}

// ParseStringToMembers parses a string of member addresses and roles.
// String should have one or more lines where each line should contain an
// address optionally followed by one or more roles.
// Example multi line string:
//
//	g1hy6zry03hg5d8le9s2w4fxme6236hkgd928dun roleA
//	g1e5hud66rs7ye4zgeqmqvwfhurs2mnf408hdqcl
//	g1vh7krmmzfua5xjmkatvmx09z37w34lsvd2mxa5 roleB roleA
//
// Addresses are validated after being parsed.
// Roles must be validated by the caller to make sure the names are valid.
func ParseStringToMembers(s string) ([]Member, error) {
	var members []Member
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			// Skip empty lines
			continue
		}

		var (
			roles  []Role
			fields = strings.Fields(line)
			addr   = std.Address(strings.TrimSpace(fields[0]))
		)

		if !addr.IsValid() {
			return nil, errors.New("invalid member address: " + EscapeHTML(addr.String()))
		}

		for _, v := range fields[1:] {
			roles = appendRole(roles, strings.TrimSpace(v))
		}

		members = append(members, NewMember(addr, roles...))
	}
	return members, nil
}

// MustParseStringToMembers parses a string of member addresses and roles.
// String should have one or more lines where each line should contain an
// address optionally followed by one or more roles.
// Example multi line string:
//
//	g1hy6zry03hg5d8le9s2w4fxme6236hkgd928dun roleA
//	g1e5hud66rs7ye4zgeqmqvwfhurs2mnf408hdqcl
//	g1vh7krmmzfua5xjmkatvmx09z37w34lsvd2mxa5 roleB roleA
//
// Addresses are validated after being parsed.
// Roles must be validated by the caller to make sure the names are valid.
func MustParseStringToMembers(s string) []Member {
	members, err := ParseStringToMembers(s)
	if err != nil {
		panic(err.Error())
	}
	return members
}

// appendRole append a role if it doesn't exists within the list of roles.
func appendRole(roles []Role, name string) []Role {
	for _, r := range roles {
		if string(r) == name {
			return roles
		}
	}
	return append(roles, Role(name))
}
