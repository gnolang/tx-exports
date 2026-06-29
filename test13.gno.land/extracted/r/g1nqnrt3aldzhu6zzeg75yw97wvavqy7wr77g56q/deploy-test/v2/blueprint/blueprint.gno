package blueprint

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/validate"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
	personal_world "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/personal_world"
)

const (
	CreateBlueprintEvent      = "CreateBlueprint"
	UpdateBlueprintEvent      = "UpdateBlueprint"
	DeleteBlueprintEvent      = "DeleteBlueprint"
	SetBlueprintMetadataEvent = "SetBlueprintMetadata"
)

func CreateBlueprint(cur realm, propKeys string, propValues string) uint32 {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)

	props := parsePropsCSV(propKeys, propValues)
	blueprintCreateValidator.MustValidate(props)

	biomeName := props["biome"]
	name := props["name"]
	size := props["size"]

	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)
	assertBlueprintName(name)
	assertBlueprintSize(size)

	if !blueprintStore.IsNameAvailable(name) {
		panic("name already exists")
	}

	cost := creationCost
	if cost > 0 {
		// MustGetUserCaller guarantees a direct user call before reading OriginSend.
		payment := unsafe.OriginSend().AmountOf("ugnot")
		assertExactPayment(cost, payment)
	}

	heightStr := strconv.FormatInt(runtime.ChainHeight(), 10)
	props["owner"] = caller.String()
	props["createdAt"] = heightStr
	props["updatedAt"] = heightStr

	id := blueprintStore.Create(props)
	idStr := formatBlueprintID(id)
	if cost > 0 {
		send(cur, admin.GetFeeCollector(), cost)
	}

	chain.Emit(
		CreateBlueprintEvent,
		"id", idStr,
		"owner", props["owner"],
		"name", props["name"],
		"biome", props["biome"],
		"cost", strconv.FormatInt(cost, 10),
	)

	return id
}

func UpdateBlueprint(cur realm, blueprintID uint32, propKeys string, propValues string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertAdminOrBlueprintOwner(blueprintID, caller)

	props := parsePropsCSV(propKeys, propValues)
	blueprintUpdateValidator.MustValidate(props)
	blueprintStore.AssertBlueprintExists(blueprintID)

	if name, found := props["name"]; found {
		assertBlueprintName(name)
	}

	props["updatedAt"] = strconv.FormatInt(runtime.ChainHeight(), 10)

	updated := blueprintStore.Update(blueprintID, props)

	chain.Emit(
		UpdateBlueprintEvent,
		"id", updated["id"],
		"owner", updated["owner"],
		"name", updated["name"],
	)
}

func DeleteBlueprint(cur realm, blueprintID uint32) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)

	blueprintStore.Delete(blueprintID)
	verifierStore.Delete(blueprintID)

	chain.Emit(
		DeleteBlueprintEvent,
		"id", formatBlueprintID(blueprintID),
	)
}

func SetBlueprintMetadata(cur realm, blueprintID uint32, metadata string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	blueprintStore.AssertBlueprintExists(blueprintID)
	validate.AssertStringTextLen(metadata, true, "blueprint metadata")
	blueprintStore.SetMetadata(blueprintID, metadata)

	chain.Emit(
		SetBlueprintMetadataEvent,
		"id", formatBlueprintID(blueprintID),
	)
}

func GetBlueprint(blueprintID uint32) map[string]string {
	assertMigrationStateAvailable()
	return blueprintStore.MustGet(blueprintID)
}

func GetBlueprintMetadata(blueprintID uint32) string {
	assertMigrationStateAvailable()
	return blueprintStore.GetMetadata(blueprintID)
}

func ListBlueprintMetadataByIDs(blueprintIDs ...uint32) []string {
	assertMigrationStateAvailable()
	assertListLimit("blueprintIDs", len(blueprintIDs))
	return blueprintStore.ListMetadataByIDs(blueprintIDs...)
}

func GetBlueprintIDByName(name string) uint32 {
	assertMigrationStateAvailable()
	return blueprintStore.MustGetIDByName(name)
}

func GetTotalBlueprintSize() int {
	assertMigrationStateAvailable()
	return blueprintStore.Total()
}

func IsNameAvailable(name string) bool {
	assertMigrationStateAvailable()
	return blueprintStore.IsNameAvailable(name)
}

func ListBlueprintIDs(page int, count int) []uint32 {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	return blueprintStore.ListIDs(page, count)
}

func ListBlueprintsByIDs(blueprintIDs ...uint32) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("blueprintIDs", len(blueprintIDs))

	if len(blueprintIDs) == 0 {
		return []map[string]string{}
	}
	return blueprintStore.ListByIDs(blueprintIDs...)
}

func GetBlueprintSizeByOwner(owner address) int {
	assertMigrationStateAvailable()
	return blueprintStore.OwnerCount(owner)
}

func ListBlueprintIDsByOwner(owner address, page int, count int) []uint32 {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	return blueprintStore.ListIDsByOwner(owner, page, count)
}

func GetBlueprintSizeByBiome(biomeName string) int {
	assertMigrationStateAvailable()
	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)
	return blueprintStore.BiomeCount(biomeName)
}

func ListBlueprintIDsByBiome(biomeName string, page int, count int) []uint32 {
	assertMigrationStateAvailable()
	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)
	assertListPageCount(page, count)
	return blueprintStore.ListIDsByBiome(biomeName, page, count)
}

func GetBlueprintSizeByState(state string) int {
	assertMigrationStateAvailable()
	return blueprintStore.StateCount(state)
}

func ListBlueprintIDsByState(state string, page int, count int) []uint32 {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	return blueprintStore.ListIDsByState(state, page, count)
}

func GetBlueprintSizeByBiomeState(biomeName string, state string) int {
	assertMigrationStateAvailable()
	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)
	return blueprintStore.BiomeStateCount(biomeName, state)
}

func ListBlueprintIDsByBiomeState(biomeName string, state string, page int, count int) []uint32 {
	assertMigrationStateAvailable()
	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)
	assertListPageCount(page, count)
	return blueprintStore.ListIDsByBiomeState(biomeName, state, page, count)
}

func assertAdminOrBlueprintOwner(blueprintID uint32, caller address) {
	if admin.IsAdmin(caller) || blueprintStore.IsOwner(blueprintID, caller) {
		return
	}
	panic("caller must be admin or blueprint owner to update blueprint " + formatBlueprintID(blueprintID))
}

func assertBiomeExists(biomeName string) {
	if !personal_world.HasBiomeInfo(biomeName) {
		panic("unknown biome")
	}
}

func send(cur realm, to address, amount int64) {
	if amount <= 0 {
		panic("amount must be greater than 0")
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	coins := chain.Coins{chain.Coin{"ugnot", amount}}
	bnk.SendCoins(realmAddr, to, coins)
}

func formatBlueprintID(blueprintID uint32) string {
	return strconv.FormatUint(uint64(blueprintID), 10)
}
