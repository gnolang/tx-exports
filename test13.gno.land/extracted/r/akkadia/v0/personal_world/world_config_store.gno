package personal_world

import "gno.land/p/akkadia/v0/ds/btree"

var worldConfigStore *WorldConfigStore = newWorldConfigStore()

// WorldConfigStore owns personal world biome and size configuration records.
//
// Data shape:
// - biomeInfos: biome(string) -> map[string]string
// - sizeInfos: sizeID(string) -> map[string]string
type WorldConfigStore struct {
	biomeInfos   *btree.StringBTree
	defaultBiome string
	sizeInfos    *btree.StringBTree
}

func newWorldConfigStore() *WorldConfigStore {
	return &WorldConfigStore{
		biomeInfos:   btree.NewStringBTree(32),
		defaultBiome: "",
		sizeInfos:    btree.NewStringBTree(32),
	}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *WorldConfigStore) BiomeInfos() *btree.StringBTree {
	return s.biomeInfos
}

func (s *WorldConfigStore) SizeInfos() *btree.StringBTree {
	return s.sizeInfos
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *WorldConfigStore) SetBiomeInfo(info map[string]string) map[string]string {
	biomeName := info["biome"]
	s.biomeInfos.Set(biomeName, copyStringMap(info))
	return copyStringMap(info)
}

func (s *WorldConfigStore) MustGetBiomeInfo(biomeName string) map[string]string {
	info, found := s.GetBiomeInfo(biomeName)
	if !found {
		panic("biome not found: " + biomeName)
	}
	return info
}

func (s *WorldConfigStore) GetBiomeInfo(biomeName string) (map[string]string, bool) {
	info, found := s.biomeInfos.Get(biomeName)
	if !found {
		return nil, false
	}
	return copyStringMap(info.(map[string]string)), true
}

func (s *WorldConfigStore) ListBiomeInfos() []map[string]string {
	result := []map[string]string{}
	s.biomeInfos.Iterate(nil, nil, func(_ string, info any) bool {
		result = append(result, copyStringMap(info.(map[string]string)))
		return false
	})
	return result
}

func (s *WorldConfigStore) HasBiomeInfo(biomeName string) bool {
	return s.biomeInfos.Has(biomeName)
}

func (s *WorldConfigStore) SetDefaultBiome(biomeName string) string {
	oldDefault := s.defaultBiome
	s.defaultBiome = biomeName
	return oldDefault
}

func (s *WorldConfigStore) DefaultBiome() string {
	return s.defaultBiome
}

func (s *WorldConfigStore) TotalBiomes() int {
	return s.biomeInfos.Size()
}

func (s *WorldConfigStore) SetSizeInfo(info map[string]string) map[string]string {
	key := info["id"]
	s.sizeInfos.Set(key, copyStringMap(info))
	return copyStringMap(info)
}

func (s *WorldConfigStore) MustGetSizeInfo(sizeID string) map[string]string {
	info, found := s.GetSizeInfo(sizeID)
	if !found {
		panic("size info not found: " + sizeID)
	}
	return info
}

func (s *WorldConfigStore) GetSizeInfo(sizeID string) (map[string]string, bool) {
	info, found := s.sizeInfos.Get(sizeID)
	if !found {
		return nil, false
	}
	return copyStringMap(info.(map[string]string)), true
}

func (s *WorldConfigStore) ListSizeInfos() []map[string]string {
	result := []map[string]string{}
	s.sizeInfos.Iterate(nil, nil, func(_ string, info any) bool {
		result = append(result, copyStringMap(info.(map[string]string)))
		return false
	})
	return result
}

func (s *WorldConfigStore) TotalSizes() int {
	return s.sizeInfos.Size()
}

func calculateExpansionCost(baseCost int64, priceMultiplierBPS int64) (int64, bool) {
	if baseCost <= 0 {
		return 0, true
	}
	if priceMultiplierBPS < 0 {
		return maxInt64, false
	}

	denominator := int64(10000)
	wholeAmount := baseCost / denominator
	remainingAmount := baseCost % denominator
	first, ok := checkedMultiply(wholeAmount, priceMultiplierBPS)
	if !ok {
		return maxInt64, false
	}
	second, ok := checkedMultiply(remainingAmount, priceMultiplierBPS)
	if !ok {
		return maxInt64, false
	}
	second = second / denominator
	total, ok := checkedAdd(first, second)
	if !ok {
		return maxInt64, false
	}
	return total, true
}

func checkedMultiply(a int64, b int64) (int64, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	if a < 0 || b < 0 || a > maxInt64/b {
		return maxInt64, false
	}
	return a * b, true
}

func checkedAdd(a int64, b int64) (int64, bool) {
	if a < 0 || b < 0 || a > maxInt64-b {
		return maxInt64, false
	}
	return a + b, true
}
