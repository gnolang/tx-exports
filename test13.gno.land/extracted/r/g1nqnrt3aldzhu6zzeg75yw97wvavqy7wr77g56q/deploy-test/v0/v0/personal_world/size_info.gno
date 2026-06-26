package personal_world

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
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
	cost, _ := worldConfigStore.ExpansionCost(world["sizeId"], world["biome"])
	return cost
}
