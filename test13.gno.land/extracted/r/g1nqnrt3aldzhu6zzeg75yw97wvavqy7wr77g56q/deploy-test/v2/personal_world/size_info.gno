package personal_world

import (
	"chain"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

const (
	SetSizeInfoEvent = "SetSizeInfo"
)

func init() {
	worldConfigStore.SetSizeInfo(map[string]string{"id": "0", "size": "100", "cost": "0"})
	worldConfigStore.SetSizeInfo(map[string]string{"id": "1", "size": "200", "cost": "20000000"})
	worldConfigStore.SetSizeInfo(map[string]string{"id": "2", "size": "300", "cost": "30000000"})
	worldConfigStore.SetSizeInfo(map[string]string{"id": "3", "size": "400", "cost": "40000000"})
}

// SetSizeInfo sets a single size info (admin only)
func SetSizeInfo(cur realm, propKeys string, propValues string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	props := parsePropertiesCSV(propKeys, propValues)

	sizeInfoValidator.MustValidate(props)
	mustParseSizeID(props["id"])
	mustParseWorldSize(props["size"])
	mustParseSizeCost(props["cost"])

	worldConfigStore.SetSizeInfo(props)

	chain.Emit(
		SetSizeInfoEvent,
		"sizeID", props["id"],
		"size", props["size"],
		"cost", props["cost"],
	)
}

func ListSizeInfos() []map[string]string {
	assertMigrationStateAvailable()
	return worldConfigStore.ListSizeInfos()
}

// GetWorldExpansionCost returns the cost to expand a world to the next size
func GetWorldExpansionCost(worldID uint32) int64 {
	assertMigrationStateAvailable()
	world := worldStore.MustGet(worldID)
	cost, _ := expansionCost(world["sizeId"], world["biome"])
	return cost
}

func mustGetNextSizeInfo(sizeID string) map[string]string {
	info, found := getNextSizeInfo(sizeID)
	if !found {
		currentSizeID, err := strconv.Atoi(sizeID)
		if err != nil {
			panic("size info not found: " + sizeID)
		}
		panic("size info not found: " + strconv.Itoa(currentSizeID+1))
	}
	return info
}

func getNextSizeInfo(sizeID string) (map[string]string, bool) {
	currentSizeID, err := strconv.Atoi(sizeID)
	if err != nil {
		return nil, false
	}
	return worldConfigStore.GetSizeInfo(strconv.Itoa(currentSizeID + 1))
}

func expansionCost(sizeID string, biomeName string) (int64, bool) {
	nextSizeInfo, found := getNextSizeInfo(sizeID)
	if !found {
		return maxInt64, false
	}
	baseCost, err := strconv.ParseInt(nextSizeInfo["cost"], 10, 64)
	if err != nil {
		return maxInt64, false
	}
	biomeInfo, found := worldConfigStore.GetBiomeInfo(biomeName)
	if !found {
		return maxInt64, false
	}
	priceMultiplierBPS, err := strconv.ParseInt(biomeInfo["priceMultiplierBPS"], 10, 64)
	if err != nil {
		return maxInt64, false
	}
	return calculateExpansionCost(baseCost, priceMultiplierBPS)
}
