package personal_world

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/r/akkadia/v0/admin"
)

const (
	CreateWorldEvent      = "CreateWorld"
	UpdateWorldEvent      = "UpdateWorld"
	ExpandWorldEvent      = "ExpandWorld"
	DeleteWorldEvent      = "DeleteWorld"
	SetWorldMetadataEvent = "SetWorldMetadata"
)

func CreateWorld(cur realm, propKeys string, propValues string) uint32 {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)

	props := parsePropertiesCSV(propKeys, propValues)
	worldCreateValidator.MustValidate(props)

	biomeName := props["biome"]
	name := props["name"]
	slug := props["slug"]
	seed := mustParseWorldSeed(props["seed"])

	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)
	assertWorldName(name)
	assertWorldSlug(slug)

	if !worldStore.IsNameAvailable(name) {
		panic("name already exists")
	}
	if !worldStore.IsSlugAvailable(slug) {
		panic("slug already exists")
	}
	// MustGetUserCaller guarantees a direct user call, so OriginSend cannot be borrowed through an intermediate realm.
	payment := unsafe.OriginSend().AmountOf("ugnot")
	cost, ok := creationCost(biomeName)
	if !ok {
		panic("invalid creation cost")
	}
	assertExactPayment(cost, payment)

	sizeInfo := worldConfigStore.MustGetSizeInfo("0")
	heightStr := strconv.FormatInt(runtime.ChainHeight(), 10)

	props["owner"] = caller.String()
	props["sizeId"] = sizeInfo["id"]
	props["size"] = sizeInfo["size"]
	props["seed"] = strconv.Itoa(seed)
	props["isVisible"] = strconv.FormatBool(true)
	props["createdAt"] = heightStr
	props["updatedAt"] = heightStr
	props["totalPaid"] = strconv.FormatInt(cost, 10)

	id := worldStore.Create(props)
	idStr := formatWorldID(id)
	feeCollectorShare, protocolShare := distribute(cur, cost)

	// Emit event with distribution details
	chain.Emit(
		CreateWorldEvent,
		"id", idStr,
		"owner", props["owner"],
		"name", props["name"],
		"slug", props["slug"],
		"seed", props["seed"],
		"cost", strconv.FormatInt(cost, 10),
		"feeCollectorShare", strconv.FormatInt(feeCollectorShare, 10),
		"protocolShare", strconv.FormatInt(protocolShare, 10),
	)

	return id
}

func UpdateWorld(cur realm, worldID uint32, propKeys string, propValues string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	if !HasUpdatePermission(worldID, caller) {
		panic("caller must be admin or world owner to update world " + formatWorldID(worldID))
	}

	props := parsePropertiesCSV(propKeys, propValues)
	worldUpdateValidator.MustValidate(props)
	worldStore.AssertWorldExists(worldID)

	if name, found := props["name"]; found {
		assertWorldName(name)
	}
	if slug, found := props["slug"]; found {
		assertWorldSlug(slug)
	}

	heightStr := strconv.FormatInt(runtime.ChainHeight(), 10)
	props["updatedAt"] = heightStr

	updated := worldStore.Update(worldID, props)

	chain.Emit(
		UpdateWorldEvent,
		"id", updated["id"],
		"name", updated["name"],
		"slug", updated["slug"],
	)
}

func ExpandWorld(cur realm, worldID uint32) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	if !HasExpandPermission(worldID, caller) {
		panic("caller must be admin or world owner to expand world " + formatWorldID(worldID))
	}

	world := worldStore.MustGet(worldID)
	oldSizeID := world["sizeId"]

	cost, ok := expansionCost(oldSizeID, world["biome"])
	if !ok {
		panic("invalid expansion cost")
	}
	// MustGetUserCaller guarantees a direct user call, so OriginSend cannot be borrowed through an intermediate realm.
	payment := unsafe.OriginSend().AmountOf("ugnot")
	assertExactPayment(cost, payment)

	nextSizeInfo := mustGetNextSizeInfo(oldSizeID)
	totalPaid := calculateTotalPaid(world, cost)
	heightStr := strconv.FormatInt(runtime.ChainHeight(), 10)
	updates := map[string]string{
		"sizeId":    nextSizeInfo["id"],
		"size":      nextSizeInfo["size"],
		"totalPaid": totalPaid,
		"updatedAt": heightStr,
	}

	worldStore.Update(worldID, updates)
	feeCollectorShare, protocolShare := distribute(cur, cost)

	chain.Emit(
		ExpandWorldEvent,
		"id", world["id"],
		"oldSizeID", oldSizeID,
		"newSizeID", nextSizeInfo["id"],
		"required", strconv.FormatInt(cost, 10),
		"totalPaid", totalPaid,
		"feeCollectorShare", strconv.FormatInt(feeCollectorShare, 10),
		"protocolShare", strconv.FormatInt(protocolShare, 10),
	)
}

func calculateTotalPaid(world map[string]string, cost int64) string {
	oldTotalPaid, _ := strconv.ParseInt(world["totalPaid"], 10, 64)
	totalPaid := safeAdd(oldTotalPaid, cost, "total paid overflow")
	return strconv.FormatInt(totalPaid, 10)
}

func DeleteWorld(cur realm, worldID uint32) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)

	worldStore.Delete(worldID)

	// Remove chunk verifiers
	verifierStore.Delete(worldID)

	// Remove all role assignments for this world
	cleanupWorldAuthorization(worldID)

	// Emit event
	chain.Emit(
		DeleteWorldEvent,
		"id", formatWorldID(worldID),
	)
}

func SetWorldMetadata(cur realm, worldID uint32, metadata string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	worldStore.AssertWorldExists(worldID)
	assertWorldMetadata(metadata)
	worldStore.SetMetadata(worldID, metadata)

	chain.Emit(
		SetWorldMetadataEvent,
		"id", formatWorldID(worldID),
	)
}

func GetWorld(worldID uint32) map[string]string {
	assertMigrationStateAvailable()
	return worldStore.MustGet(worldID)
}

func GetWorldMetadata(worldID uint32) string {
	assertMigrationStateAvailable()
	return worldStore.GetMetadata(worldID)
}

func ListWorldMetadataByIDs(worldIDs ...uint32) []string {
	assertMigrationStateAvailable()
	assertListLimit("worldIDs", len(worldIDs))
	return worldStore.ListMetadataByIDs(worldIDs...)
}

func GetWorldBySlug(slug string) map[string]string {
	assertMigrationStateAvailable()
	worldID := worldStore.MustGetIDBySlug(slug)
	return worldStore.MustGet(worldID)
}

func GetWorldIDBySlug(slug string) uint32 {
	assertMigrationStateAvailable()
	return worldStore.MustGetIDBySlug(slug)
}

func GetWorldIDByName(name string) uint32 {
	assertMigrationStateAvailable()
	return worldStore.MustGetIDByName(name)
}

func GetTotalWorldSize() int {
	assertMigrationStateAvailable()
	return worldStore.Total()
}

func IsNameAvailable(name string) bool {
	assertMigrationStateAvailable()
	return worldStore.IsNameAvailable(name)
}

func IsSlugAvailable(slug string) bool {
	assertMigrationStateAvailable()
	return worldStore.IsSlugAvailable(slug)
}

func ListWorldIDs(page, count int) []uint32 {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	return worldStore.ListIDs(page, count)
}

func ListWorldsByIDs(worldIDs ...uint32) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("worldIDs", len(worldIDs))

	if len(worldIDs) == 0 {
		return []map[string]string{}
	}

	return worldStore.ListByIDs(worldIDs...)
}

func GetWorldSizeByOwner(owner address) int {
	assertMigrationStateAvailable()
	return worldStore.OwnerCount(owner)
}

func ListWorldIDsByOwner(owner address, page int, count int) []uint32 {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	return worldStore.ListIDsByOwner(owner, page, count)
}

func assertExactPayment(expected int64, actual int64) {
	if actual != expected {
		panic("exact payment required: expected " + strconv.FormatInt(expected, 10) + ", got " + strconv.FormatInt(actual, 10))
	}
}

func distribute(cur realm, cost int64) (int64, int64) {
	if cost <= 0 {
		return 0, 0
	}

	feeCollectorShare, protocolShare := calculateBPSShares(cost, int64(feeCollectorBPS))
	if feeCollectorShare > 0 {
		send(cur, admin.GetFeeCollector(), feeCollectorShare)
	}
	if protocolShare > 0 {
		send(cur, admin.GetProtocol(), protocolShare)
	}
	return feeCollectorShare, protocolShare
}

func send(cur realm, to address, amount int64) {
	if amount <= 0 {
		panic("amount must be greater than 0")
	}
	// Send funds to feeCollector and protocol
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	coins := chain.Coins{chain.Coin{"ugnot", amount}}
	bnk.SendCoins(realmAddr, to, coins)
}
