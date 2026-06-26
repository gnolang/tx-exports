package chunk

import (
	"chain"
	"chain/runtime"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const (
	CreateWorldEvent = "CreateWorld"
	UpdateWorldEvent = "UpdateWorld"
)

func CreateWorld(cur realm, id uint32, propKeys string, propValues string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	assertWorldID(id)
	props := parsePropertiesCSV(propKeys, propValues)
	worldCreateValidator.MustValidate(props)

	biomeName := props["biome"]
	name := props["name"]
	slug := props["slug"]
	mustParseWorldSeed(props["seed"])

	assertBiomeName(biomeName)
	assertWorldName(name)
	assertWorldSlug(slug)
	if worldStore.Has(id) {
		panic("world already exists: " + formatWorldID(id))
	}
	if !worldStore.IsNameAvailable(name) {
		panic("name already exists: " + name)
	}
	if !worldStore.IsSlugAvailable(slug) {
		panic("slug already exists: " + slug)
	}

	heightStr := strconv.FormatInt(runtime.ChainHeight(), 10)
	props["id"] = formatWorldID(id)
	props["createdAt"] = heightStr
	props["updatedAt"] = heightStr

	world := worldStore.Create(id, props)

	chain.Emit(
		CreateWorldEvent,
		"id", world["id"],
		"biome", world["biome"],
		"name", world["name"],
		"slug", world["slug"],
		"seed", world["seed"],
	)
}

func UpdateWorld(cur realm, worldID uint32, propKeys string, propValues string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	assertWorldID(worldID)
	props := parsePropertiesCSV(propKeys, propValues)
	worldUpdateValidator.MustValidate(props)

	world := worldStore.MustGet(worldID)

	if biomeName, found := props["biome"]; found {
		assertBiomeName(biomeName)
	}
	if name, found := props["name"]; found && name != world["name"] {
		assertWorldName(name)
		if !worldStore.IsNameAvailable(name) {
			panic("name already exists: " + name)
		}
	}
	if slug, found := props["slug"]; found && slug != world["slug"] {
		assertWorldSlug(slug)
		if !worldStore.IsSlugAvailable(slug) {
			panic("slug already exists: " + slug)
		}
	}

	for key, value := range props {
		world[key] = value
	}
	world["updatedAt"] = strconv.FormatInt(runtime.ChainHeight(), 10)
	updatedWorld := worldStore.Update(worldID, world)

	chain.Emit(
		UpdateWorldEvent,
		"id", updatedWorld["id"],
		"biome", updatedWorld["biome"],
		"name", updatedWorld["name"],
		"slug", updatedWorld["slug"],
	)
}

func GetWorld(worldID uint32) map[string]string {
	assertMigrationStateAvailable()
	return worldStore.MustGet(worldID)
}

func GetWorldBySlug(slug string) map[string]string {
	assertMigrationStateAvailable()
	return worldStore.MustGetBySlug(slug)
}

func GetTotalWorldSize() int {
	assertMigrationStateAvailable()
	return worldStore.Total()
}

func ListWorlds(page, count int) []map[string]string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)

	return worldStore.List(page, count)
}

func ListWorldsByIDs(worldIDs ...uint32) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("worldIDs", len(worldIDs))

	if len(worldIDs) == 0 {
		return []map[string]string{}
	}

	return worldStore.ListByIDs(worldIDs...)
}
