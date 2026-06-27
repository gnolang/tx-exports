package personal_world

import (
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/rbac"
	oldpw "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/personal_world"
)

type WorldStore = oldpw.WorldStore
type WorldConfigStore = oldpw.WorldConfigStore
type VerifierStore = oldpw.VerifierStore

const (
	MigrationResearchExpectedBiome          = "migration_research_biome"
	MigrationResearchExpectedBiomeName      = "Migration Research Biome"
	MigrationResearchExpectedRole           = "migration_research_role"
	MigrationResearchExpectedRoleLabel      = "Migration Research Role"
	MigrationResearchExpectedPermission     = "migration:research"
	MigrationResearchExpectedPermissionDesc = "Migration Research Permission"
	MigrationResearchExpectedGrantableRole  = "editor"
)

var MigrationResearchExpectedGrantee = address("g1x8l886kqzdlqt8v0znrj89mhas0h242caseqe9")

var (
	worldStore             *WorldStore
	worldConfigStore       *WorldConfigStore
	verifierStore          *VerifierStore
	feeCollectorBPS        int
	listLimit              int
	batchLimit             int
	frozen                 bool
	personalWorldAuthzRBAC *rbac.RBAC
)

func IsFrozen() bool {
	return frozen
}

func Unfreeze(cur realm) {
	frozen = false
}

func GetFeeCollectorBPS() int {
	return feeCollectorBPS
}

func GetDefaultBiome() string {
	return worldConfigStore.DefaultBiome()
}

func GetBiomeInfo(biomeName string) map[string]string {
	return worldConfigStore.MustGetBiomeInfo(biomeName)
}

func GetWorldExpansionCost(worldID uint32) int64 {
	world := worldStore.MustGet(worldID)
	cost, _ := worldConfigStore.ExpansionCost(world["sizeId"], world["biome"])
	return cost
}

func GetTotalWorldSize() int {
	return worldStore.Total()
}

func GetWorld(worldID uint32) map[string]string {
	return worldStore.MustGet(worldID)
}

func GetWorldIDBySlug(slug string) uint32 {
	return worldStore.MustGetIDBySlug(slug)
}

func GetWorldIDByName(name string) uint32 {
	return worldStore.MustGetIDByName(name)
}

func GetWorldBySlug(slug string) map[string]string {
	return worldStore.MustGet(worldStore.MustGetIDBySlug(slug))
}

func GetWorldSizeByOwner(owner address) int {
	return worldStore.OwnerCount(owner)
}

func IsSlugAvailable(slug string) bool {
	return worldStore.IsSlugAvailable(slug)
}

func CreateWorld(cur realm, propKeys string, propValues string) uint32 {
	props := migrationResearchProperties(propKeys, propValues)
	id := worldStore.NextID()
	props["id"] = formatWorldID(id)
	props["owner"] = cur.Previous().Address().String()
	props["sizeId"] = defaultString(props["sizeId"], "0")
	props["size"] = defaultString(props["size"], worldConfigStore.MustGetSizeInfo("0")["size"])
	props["isVisible"] = defaultString(props["isVisible"], "true")
	props["createdAt"] = defaultString(props["createdAt"], "0")
	props["updatedAt"] = defaultString(props["updatedAt"], "0")
	props["totalPaid"] = defaultString(props["totalPaid"], "0")
	return worldStore.Create(props)
}

func UpdateWorld(cur realm, worldID uint32, propKeys string, propValues string) {
	world := copyStringMap(worldStore.MustGet(worldID))
	props := migrationResearchProperties(propKeys, propValues)
	for key, value := range props {
		world[key] = value
	}
	world["updatedAt"] = "0"
	worldStore.Update(worldID, world)
}

func ExpandWorld(cur realm, worldID uint32) {
	world := copyStringMap(worldStore.MustGet(worldID))
	nextSizeInfo := worldConfigStore.MustGetNextSizeInfo(world["sizeId"])
	world["sizeId"] = nextSizeInfo["id"]
	world["size"] = nextSizeInfo["size"]
	world["updatedAt"] = "0"
	worldStore.Update(worldID, world)
}

func DeleteWorld(cur realm, worldID uint32) {
	worldStore.Delete(worldID)
	verifierStore.Delete(worldID)
	personalWorldAuthzRBAC.DeleteEntity(formatWorldID(worldID))
}

func GetPermission(name string) map[string]string {
	if !personalWorldAuthzRBAC.HasPermission(name) {
		return nil
	}
	permission := personalWorldAuthzRBAC.GetPermission(name)
	return map[string]string{
		"name":        permission.Name,
		"description": permission.Description,
	}
}

func GetRoleInfo(roleName string) map[string]string {
	if !personalWorldAuthzRBAC.HasRole(roleName) {
		return nil
	}
	role := personalWorldAuthzRBAC.GetRole(roleName)
	info := copyStringMap(role.Metadata)
	info["name"] = role.Name
	return info
}

func ListGrantables(granterRole string, page int, count int) []string {
	if !personalWorldAuthzRBAC.HasRole(granterRole) {
		return []string{}
	}
	return personalWorldAuthzRBAC.ListGrantableRoles(granterRole, page, count)
}

func GrantRole(cur realm, worldID uint32, roleName string, user address) {
	worldStore.AssertWorldExists(worldID)
	personalWorldAuthzRBAC.AssignRole(formatWorldID(worldID), user, roleName)
}

func RevokeRole(cur realm, worldID uint32, roleName string, user address) {
	worldStore.AssertWorldExists(worldID)
	personalWorldAuthzRBAC.UnassignRole(formatWorldID(worldID), user, roleName)
}

func HasRole(worldID uint32, user address, roleName string) bool {
	if !personalWorldAuthzRBAC.HasRole(roleName) {
		return false
	}
	return personalWorldAuthzRBAC.HasUserRole(formatWorldID(worldID), user, roleName)
}

func ListRoleGrants(worldID uint32, roleName string, page int, count int) []address {
	if !personalWorldAuthzRBAC.HasRole(roleName) {
		return []address{}
	}
	return personalWorldAuthzRBAC.ListRoleUsers(formatWorldID(worldID), roleName, page, count)
}

func ListWorldIDsByUserRole(user address, roleName string, page int, count int) []uint32 {
	if !personalWorldAuthzRBAC.HasRole(roleName) {
		return []uint32{}
	}
	result := []uint32{}
	worldIDs := personalWorldAuthzRBAC.ListEntitiesByUserRole(user, roleName, page, count)
	for _, worldKey := range worldIDs {
		worldID, err := strconv.ParseUint(worldKey, 10, 32)
		if err != nil {
			panic("invalid worldID: " + worldKey)
		}
		result = append(result, uint32(worldID))
	}
	return result
}

func formatWorldID(worldID uint32) string {
	return strconv.FormatUint(uint64(worldID), 10)
}

func migrationResearchProperties(keys string, values string) map[string]string {
	if keys == "" {
		panic("properties keys must be not empty")
	}
	keyList := strings.Split(keys, ",")
	valueList := strings.Split(values, ",")
	if len(keyList) != len(valueList) {
		panic("properties keys and values count mismatch")
	}
	result := map[string]string{}
	for i, key := range keyList {
		if key == "" {
			panic("properties key must be not empty")
		}
		result[key] = valueList[i]
	}
	return result
}

func defaultString(value string, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func copyStringMap(source map[string]string) map[string]string {
	if source == nil {
		return nil
	}
	result := map[string]string{}
	for key, value := range source {
		result[key] = value
	}
	return result
}
