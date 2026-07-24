package addrset

import (
	"gno.land/p/nt/avl/v0"
)

type Set struct {
	tree avl.Tree
}

func New() *Set {
	return &Set{}
}

func (s *Set) Add(addr string) {
	s.tree.Set(addr, true)
}

func (s *Set) Has(addr string) bool {
	_, exists := s.tree.Get(addr)
	return exists
}
