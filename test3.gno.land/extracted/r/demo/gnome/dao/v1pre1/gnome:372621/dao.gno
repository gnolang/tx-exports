package gnome

import (
	"errors"
	"std"
	"strings"
	"time"
)

const daoPathSep = "/"

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
func WithMembers(addreses ...std.Address) Option {
	return func(dao *DAO) {
		dao.members = addreses
	}
}

// New creates a new DAO.
func New(name, title, manifest string, options ...Option) (*DAO, error) {
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

	manifest = strings.TrimSpace(manifest)
	if manifest == "" {
		return nil, errors.New("DAO manifest is required")
	}

	dao := &DAO{
		name:      name,
		title:     title,
		manifest:  manifest,
		createdAt: time.Now(),
	}

	for _, apply := range options {
		apply(dao)
	}

	return dao, nil
}

// MustNew creates a new DAO.
// The function panics if any of the arguments is not valid.
func MustNew(name, title, manifest string, options ...Option) *DAO {
	dao, err := New(name, title, manifest, options...)
	if err != nil {
		panic(err)
	}
	return dao
}

// DAO is a decentralized autonomous organization.
type DAO struct {
	name           string
	title          string
	manifest       string // TODO: Rename to "purpose"?
	isSuperCouncil bool
	parent         *DAO
	children       []*DAO
	members        []std.Address
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
// For the main DAO the result is nil.
func (dao DAO) Parent() *DAO {
	return dao.parent
}

// Path returns the path of the DAO.
func (dao DAO) Path() string {
	if dao.parent == nil {
		return dao.name
	}
	return MakePath(dao.parent.Path(), dao.name)
}

// SubDAOs returns the sub DAOs.
func (dao DAO) SubDAOs() []*DAO {
	return dao.children
}

// GetFirstSubDAO returns the first sub DAO.
func (dao DAO) GetFirstSubDAO() *DAO {
	if len(dao.children) == 0 {
		return nil
	}
	return dao.children[0]
}

// Members returns the members of the DAOs.
func (dao DAO) Members() []std.Address {
	return dao.members
}

// IsSuperCouncil checks if the DAO is a super council.
func (dao DAO) IsSuperCouncil() bool {
	return dao.isSuperCouncil
}

// HasMember checks if a member is part of the DAO.
func (dao DAO) HasMember(addr std.Address) bool {
	for _, m := range dao.members {
		if m == addr {
			return true
		}
	}
	return false
}

// AddMember adds a member to the DAO.
// Caller must check the member before adding to avoid duplications.
func (dao *DAO) AddMember(addr std.Address) {
	dao.members = append(dao.members, addr)
}

// GetMember gets a member of the DAO.
func (dao DAO) GetMember(addr std.Address) (std.Address, bool) {
	for _, m := range dao.members {
		if m == addr {
			return m, true
		}
	}
	return "", false
}

// RemoveMember removes a member of the DAO.
func (dao *DAO) RemoveMember(addr std.Address) bool {
	for i, m := range dao.members {
		if m == addr {
			dao.members = append(dao.members[:i], dao.members[i+1:]...)
			return true
		}
	}
	return false
}

// AddSubDAO adds a sub DAO to the DAO.
func (dao *DAO) AddSubDAO(sub *DAO) bool {
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
	path = strings.TrimPrefix(path, dao.name+daoPathSep)

	// Split DAO path in child name and relative sub path
	parts := strings.SplitN(path, daoPathSep, 2)
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

// MakePath creates a new DAO path.
func MakePath(items ...string) string {
	return strings.Join(items, daoPathSep)
}
