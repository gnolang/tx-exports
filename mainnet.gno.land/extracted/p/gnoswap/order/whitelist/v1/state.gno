package whitelist

import (
	rotree "gno.land/p/nt/bptree/rotree/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

// State holds one independently managed pool whitelist.
type State struct {
	pools *bptree.BPTree
}

func NewState() State {
	return State{pools: bptree.NewBPTreeN(16)}
}

func (s *State) AddPool(poolPath string) {
	s.pools.Set(poolPath, true)
}

func (s *State) RemovePool(poolPath string) {
	s.pools.Remove(poolPath)
}

func (s *State) HasPool(poolPath string) bool {
	return s.pools.Has(poolPath)
}

// Pools exposes membership and iteration without mutable tree access.
func (s *State) Pools() *rotree.ReadOnlyTree {
	return rotree.Wrap(s.pools, nil)
}
