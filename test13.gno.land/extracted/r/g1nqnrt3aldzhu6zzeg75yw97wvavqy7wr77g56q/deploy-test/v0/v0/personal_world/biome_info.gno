package personal_world

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const (
	SetBiomeInfoEvent    = "SetBiomeInfo"
	SetDefaultBiomeEvent = "SetDefaultBiome"
)

func init() {
	worldConfigStore.SetBiomeInfo(map[string]string{
		"biome":              "everdawn_plains",
		"cost":               "100000000",
		"priceMultiplierBPS": "10000",
		"name":               "Everdawn Plains",
		"description":        "The beginning of all things — a peaceful grassland bathed in eternal morning light.",
		"theme":              "origin,serenity",
	})
	worldConfigStore.SetDefaultBiome("everdawn_plains")
}

// SetBiomeInfo sets a single biome info (admin only).
// priceMultiplierBPS uses 10_000 as 1x.
func SetBiomeInfo(cur realm, propKeys string, propValues string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	props := parsePropertiesCSV(propKeys, propValues)

	biomeInfoValidator.MustValidate(props)
	assertBiomeName(props["biome"])
	mustParseBiomeCost(props["cost"])
	mustParseBiomePriceMultiplierBPS(props["priceMultiplierBPS"])

	worldConfigStore.SetBiomeInfo(props)

	chain.Emit(
		SetBiomeInfoEvent,
		"biome", props["biome"],
		"cost", props["cost"],
		"priceMultiplierBPS", props["priceMultiplierBPS"],
	)
}

func GetBiomeInfo(biomeName string) map[string]string {
	assertMigrationStateAvailable()
	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)
	return worldConfigStore.MustGetBiomeInfo(biomeName)
}

func HasBiomeInfo(biomeName string) bool {
	assertMigrationStateAvailable()
	return worldConfigStore.HasBiomeInfo(biomeName)
}

func ListBiomeInfos() []map[string]string {
	assertMigrationStateAvailable()
	return worldConfigStore.ListBiomeInfos()
}

// GetActualCreationCost returns the biome creation cost.
func GetActualCreationCost(biome string) int64 {
	assertMigrationStateAvailable()
	assertBiomeName(biome)
	assertBiomeExists(biome)
	cost, ok := worldConfigStore.CreationCost(biome)
	if !ok {
		panic("invalid creation cost")
	}
	return cost
}

// SetDefaultBiome sets the default biome (admin only)
func SetDefaultBiome(cur realm, biomeName string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)

	oldDefault := worldConfigStore.SetDefaultBiome(biomeName)

	chain.Emit(
		SetDefaultBiomeEvent,
		"oldDefault", oldDefault,
		"newDefault", worldConfigStore.DefaultBiome(),
	)
}

// GetDefaultBiome returns the current default biome name
func GetDefaultBiome() string {
	assertMigrationStateAvailable()
	return worldConfigStore.DefaultBiome()
}

func assertBiomeExists(biomeName string) {
	if !worldConfigStore.HasBiomeInfo(biomeName) {
		panic("unknown biome")
	}
}
