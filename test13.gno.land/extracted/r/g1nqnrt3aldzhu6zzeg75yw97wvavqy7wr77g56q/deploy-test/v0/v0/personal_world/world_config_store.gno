package personal_world

import "strconv"

var worldConfigStore *WorldConfigStore = newWorldConfigStore()

type WorldConfigStore struct {
	biomeInfos   map[string]map[string]string
	defaultBiome string
	sizeInfos    map[string]map[string]string
}

func newWorldConfigStore() *WorldConfigStore {
	return &WorldConfigStore{
		biomeInfos:   map[string]map[string]string{},
		defaultBiome: "",
		sizeInfos:    map[string]map[string]string{},
	}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *WorldConfigStore) BiomeInfos() map[string]map[string]string {
	return s.biomeInfos
}

func (s *WorldConfigStore) SizeInfos() map[string]map[string]string {
	return s.sizeInfos
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *WorldConfigStore) SetBiomeInfo(info map[string]string) map[string]string {
	biomeName := info["biome"]
	s.biomeInfos[biomeName] = copyStringMap(info)
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
	info, found := s.biomeInfos[biomeName]
	if !found {
		return nil, false
	}
	return copyStringMap(info), true
}

func (s *WorldConfigStore) ListBiomeInfos() []map[string]string {
	result := []map[string]string{}
	for _, info := range s.biomeInfos {
		result = append(result, copyStringMap(info))
	}
	return result
}

func (s *WorldConfigStore) HasBiomeInfo(biomeName string) bool {
	_, found := s.biomeInfos[biomeName]
	return found
}

func (s *WorldConfigStore) CreationCost(biomeName string) (int64, bool) {
	info, found := s.GetBiomeInfo(biomeName)
	if !found {
		return maxInt64, false
	}
	cost, err := strconv.ParseInt(info["cost"], 10, 64)
	if err != nil {
		return maxInt64, false
	}
	return cost, true
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
	return len(s.biomeInfos)
}

func (s *WorldConfigStore) SetSizeInfo(info map[string]string) map[string]string {
	key := info["id"]
	s.sizeInfos[key] = copyStringMap(info)
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
	info, found := s.sizeInfos[sizeID]
	if !found {
		return nil, false
	}
	return copyStringMap(info), true
}

func (s *WorldConfigStore) MustGetNextSizeInfo(sizeID string) map[string]string {
	info, found := s.GetNextSizeInfo(sizeID)
	if !found {
		currentSizeID, err := strconv.Atoi(sizeID)
		if err != nil {
			panic("size info not found: " + sizeID)
		}
		panic("size info not found: " + strconv.Itoa(currentSizeID+1))
	}
	return info
}

func (s *WorldConfigStore) GetNextSizeInfo(sizeID string) (map[string]string, bool) {
	currentSizeID, err := strconv.Atoi(sizeID)
	if err != nil {
		return nil, false
	}
	return s.GetSizeInfo(strconv.Itoa(currentSizeID + 1))
}

func (s *WorldConfigStore) ListSizeInfos() []map[string]string {
	result := []map[string]string{}
	for _, info := range s.sizeInfos {
		result = append(result, copyStringMap(info))
	}
	return result
}

func (s *WorldConfigStore) ExpansionCost(sizeID string, biomeName string) (int64, bool) {
	nextSizeInfo, found := s.GetNextSizeInfo(sizeID)
	if !found {
		return maxInt64, false
	}
	baseCost, err := strconv.ParseInt(nextSizeInfo["cost"], 10, 64)
	if err != nil {
		return maxInt64, false
	}
	biomeInfo, found := s.GetBiomeInfo(biomeName)
	if !found {
		return maxInt64, false
	}
	priceMultiplierBPS, err := strconv.ParseInt(biomeInfo["priceMultiplierBPS"], 10, 64)
	if err != nil {
		return maxInt64, false
	}
	return calculateExpansionCost(baseCost, priceMultiplierBPS)
}

func (s *WorldConfigStore) TotalSizes() int {
	return len(s.sizeInfos)
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
