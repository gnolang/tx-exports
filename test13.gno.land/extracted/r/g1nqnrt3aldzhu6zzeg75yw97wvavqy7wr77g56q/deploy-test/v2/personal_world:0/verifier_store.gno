package personal_world

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btree"

var verifierStore *VerifierStore = newVerifierStore()

// VerifierStore owns chunk verifier records.
//
// Data shape:
// - verifiers: worldID(uint32) -> *StringBTree(canonicalChunkKey(string) -> verifier(string))
type VerifierStore struct {
	verifiers *btree.Uint32BTree
}

func newVerifierStore() *VerifierStore {
	return &VerifierStore{verifiers: btree.NewUint32BTree(32)}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *VerifierStore) Verifiers() *btree.Uint32BTree {
	return s.verifiers
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *VerifierStore) Set(worldID uint32, chunkKey string, verifier string) {
	t := s.getOrCreateWorldTree(worldID)
	t.Set(chunkKey, verifier)
}

func (s *VerifierStore) Get(worldID uint32, chunkKey string) (string, bool) {
	t := s.getWorldTree(worldID)
	if t == nil {
		return "", false
	}
	result, found := t.Get(chunkKey)
	if !found {
		return "", false
	}
	return result.(string), true
}

func (s *VerifierStore) Delete(worldID uint32) {
	s.verifiers.Remove(worldID)
}

func (s *VerifierStore) Size(worldID uint32) int {
	t := s.getWorldTree(worldID)
	if t == nil {
		return 0
	}
	return t.Size()
}

func (s *VerifierStore) Total() int {
	total := 0
	s.verifiers.Iterate(nil, nil, func(_ uint32, value any) bool {
		total += value.(*btree.StringBTree).Size()
		return false
	})
	return total
}

func (s *VerifierStore) getWorldTree(worldID uint32) *btree.StringBTree {
	value, exists := s.verifiers.Get(worldID)
	if !exists {
		return nil
	}
	return value.(*btree.StringBTree)
}

func (s *VerifierStore) getOrCreateWorldTree(worldID uint32) *btree.StringBTree {
	if value, exists := s.verifiers.Get(worldID); exists {
		return value.(*btree.StringBTree)
	}
	t := btree.NewStringBTree(32)
	s.verifiers.Set(worldID, t)
	return t
}
