package gnome

import (
	"gno.land/p/demo/avl"

	gnome "gno.land/p/ecodevx/dao"
)

var (
	daos           daoIndex
	proposals      proposalIndex
	lastProposalID gnome.ID
)

func init() {
	// Index initial council and main DAO
	mainDAO := gnomeDAO.SubDAOs()[0]
	daos.IndexByPath(gnomeDAO)
	daos.IndexByPath(mainDAO)
}

func genProposalID() gnome.ID {
	lastProposalID += 1
	return lastProposalID
}

// TODO: Deprecate DAO index in favor of using DAO methods
type daoIndex struct {
	index avl.Tree // string(DAO path) -> *gnome.DAO
}

// IndexByPath indexes a DAO by its path.
func (x *daoIndex) IndexByPath(dao *gnome.DAO) bool {
	return x.index.Set(dao.Path(), dao)
}

// GetByPath gets a DAO by its path.
func (x daoIndex) GetByPath(path string) (*gnome.DAO, bool) {
	if v, ok := x.index.Get(path); ok {
		return v.(*gnome.DAO), true
	}
	return nil, false
}

// HasPathKey checks if a key with a DAO path exists.
func (x daoIndex) HasPathKey(path string) bool {
	return x.index.Has(path)
}

type proposalIndex struct {
	index  avl.Tree // string(binary gnome.ID) -> *gnome.Proposal
	groups avl.Tree // string(DAO path) -> []*gnome.Proposal
}

// Index indexes a proposal by its ID and DAO.
func (x *proposalIndex) Index(p *gnome.Proposal) {
	x.IndexByID(p)
	x.IndexByDAO(p)
}

// IndexByID indexes a proposal by its ID.
func (x *proposalIndex) IndexByID(p *gnome.Proposal) bool {
	return x.index.Set(p.ID().Key(), p)
}

// IndexByDAO indexes a proposal for a DAO.
func (x *proposalIndex) IndexByDAO(p *gnome.Proposal) bool {
	daoPath := p.DAO().Path()
	proposals := x.GetAllByDAO(daoPath)
	proposals = append([]*gnome.Proposal{p}, proposals...) // reverse append
	return x.groups.Set(daoPath, proposals)
}

// GetByID gets a proposal by its ID.
func (x proposalIndex) GetByID(id gnome.ID) (*gnome.Proposal, bool) {
	if v, exists := x.index.Get(id.Key()); exists {
		return v.(*gnome.Proposal), true
	}
	return nil, false
}

// GetAllByDAO gets all proposals of a DAO.
func (x proposalIndex) GetAllByDAO(daoPath string) []*gnome.Proposal {
	if v, exists := x.groups.Get(daoPath); exists {
		return v.([]*gnome.Proposal)
	}
	return nil
}

// Iterate iterates proposals starting from the oldest one.
func (x proposalIndex) Iterate(fn gnome.ProposalIterFn) bool {
	return x.index.Iterate("", "", func(_ string, v interface{}) bool {
		return fn(v.(*gnome.Proposal))
	})
}

// ReverseIterate iterates proposals starting from the latest one.
func (x proposalIndex) ReverseIterate(fn gnome.ProposalIterFn) bool {
	return x.index.ReverseIterate("", "", func(_ string, v interface{}) bool {
		return fn(v.(*gnome.Proposal))
	})
}
