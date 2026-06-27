package blueprint

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btree"

var verifierStore *VerifierStore = newVerifierStore()

// VerifierStore owns opaque blueprint chunk verifiers.
//
// Data shape:
// - verifiers: blueprintID(uint32) -> *StringBTree(chunkKey(string) -> verifier(string))
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

func (s *VerifierStore) Set(blueprintID uint32, chunkKey string, verifier string) {
	t := s.getOrCreateBlueprintTree(blueprintID)
	t.Set(chunkKey, verifier)
}

func (s *VerifierStore) Get(blueprintID uint32, chunkKey string) (string, bool) {
	t := s.getBlueprintTree(blueprintID)
	if t == nil {
		return "", false
	}
	data, found := t.Get(chunkKey)
	if !found {
		return "", false
	}
	return data.(string), true
}

func (s *VerifierStore) Delete(blueprintID uint32) {
	s.verifiers.Remove(blueprintID)
}

func (s *VerifierStore) Size(blueprintID uint32) int {
	t := s.getBlueprintTree(blueprintID)
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

func (s *VerifierStore) getBlueprintTree(blueprintID uint32) *btree.StringBTree {
	value, exists := s.verifiers.Get(blueprintID)
	if !exists {
		return nil
	}
	return value.(*btree.StringBTree)
}

func (s *VerifierStore) getOrCreateBlueprintTree(blueprintID uint32) *btree.StringBTree {
	if value, exists := s.verifiers.Get(blueprintID); exists {
		return value.(*btree.StringBTree)
	}
	t := btree.NewStringBTree(32)
	s.verifiers.Set(blueprintID, t)
	return t
}
