package chunk

import (
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/grc721"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/rbac"
	oldchunk "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/chunk"
)

type WorldStore = oldchunk.WorldStore
type NFTStore = oldchunk.NFTStore
type VerifierStore = oldchunk.VerifierStore
type ChunkGRC721Token = oldchunk.ChunkGRC721Token

const (
	MigrationResearchExpectedWorldType      = "migration_research"
	MigrationResearchExpectedWorldName      = "Migration Research Chunk World"
	MigrationResearchExpectedWorldSlug      = "migration-research-chunk-world"
	MigrationResearchExpectedRole           = "migration_research_role"
	MigrationResearchExpectedRoleLabel      = "Migration Research Role"
	MigrationResearchExpectedPermission     = "migration:research"
	MigrationResearchExpectedPermissionDesc = "Migration Research Permission"
	MigrationResearchExpectedGrantableRole  = "editor"
	MigrationResearchUpdatedWorldName       = "Migration Research Chunk World Updated"
	MigrationResearchUpdatedWorldSlug       = "migration-research-chunk-world-updated"
	MigrationResearchUpdatedWorldProperty   = "updated"
	MigrationResearchUpdatedWorldRegion     = "migration_region_updated"
	MigrationResearchUpdatedHash            = "migration_hash_updated"
	MigrationResearchUpdatedVerifier        = "migration_verifier_updated"
)

var MigrationResearchExpectedGrantee = address("g1x8l886kqzdlqt8v0znrj89mhas0h242caseqe9")

const metadataSeparator = "|"

var (
	worldStore     *WorldStore
	nftStore       *NFTStore
	verifierStore  *VerifierStore
	listLimit      int
	batchLimit     int
	frozen         bool
	chunkAuthzRBAC *rbac.RBAC
	worldAuthzRBAC *rbac.RBAC
)

func TokenCount() int64 {
	return nftStore.TokenCount()
}

func BalanceOf(user address) int64 {
	balance, err := nftStore.BalanceOf(user)
	if err != nil {
		panic("balanceOf failed: " + err.Error())
	}
	return balance
}

func OwnerOf(tokenID grc721.TokenID) address {
	owner, found := nftStore.OwnerOfSafe(tokenID)
	if !found {
		_, err := nftStore.OwnerOf(tokenID)
		panic("ownerOf failed: " + err.Error())
	}
	return owner
}

func TransferFrom(cur realm, from address, to address, tokenID grc721.TokenID) {
	worldID, _, _ := parseChunkKey(string(tokenID))
	err := nftStore.Transfer(from, from, to, tokenID, worldID)
	if err != nil {
		panic("transferFrom failed: " + err.Error())
	}
	chunkAuthzRBAC.DeleteEntity(tokenID.String())
}

func Mint(cur realm, to address, worldType string, worldID uint32, x int, y int, chunkHashKey string, chunkVerifier string) grc721.TokenID {
	worldStore.AssertExists(worldID)
	chunkKey := buildChunkKey(worldID, x, y)
	tokenID := grc721.TokenID(chunkKey)
	err := nftStore.Mint(to, tokenID, worldID, buildChunkMetadataValue(worldType, chunkHashKey))
	if err != nil {
		panic("mint failed for " + chunkKey + ": " + err.Error())
	}
	if chunkVerifier != "" {
		verifierStore.Set(worldID, chunkKey, chunkVerifier)
	}
	return tokenID
}

func SetChunkMetadata(cur realm, worldType string, worldID uint32, x int32, y int32, hash string) {
	worldStore.AssertExists(worldID)
	tokenID := grc721.TokenID(buildChunkKey(worldID, int(x), int(y)))
	nftStore.SetChunkMetadata(worldID, tokenID, buildChunkMetadataValue(worldType, hash))
}

func GetChunkMetadata(chunkKey string) map[string]string {
	worldID, _, _ := parseChunkKey(chunkKey)
	row := nftStore.GetChunkMetadata(worldID, grc721.TokenID(chunkKey))
	if row == nil {
		return nil
	}
	return buildMetadataResponse(row)
}

func GetChunkMetadataSizeByWorld(worldID uint32) int {
	return nftStore.WorldMetadataSize(worldID)
}

func GetOwnerTokenSize(worldID uint32, owner address) int {
	return nftStore.OwnerTokenSize(worldID, owner)
}

func ListChunkKeysByOwner(worldID uint32, owner address, page int, count int) []string {
	return nftStore.ListTokenIDsByOwner(worldID, owner, page, count)
}

func SetChunkVerifier(cur realm, worldID uint32, chunkKey string, verifier string) {
	verifierStore.Set(worldID, normalizeChunkKey(worldID, chunkKey), verifier)
}

func GetChunkVerifier(worldID uint32, chunkKey string) string {
	verifier, found := verifierStore.Get(worldID, normalizeChunkKey(worldID, chunkKey))
	if !found {
		return ""
	}
	return verifier
}

func GetTotalWorldSize() int {
	return worldStore.Total()
}

func GetWorld(worldID uint32) map[string]string {
	return worldStore.MustGet(worldID)
}

func GetWorldBySlug(slug string) map[string]string {
	return worldStore.MustGetBySlug(slug)
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

func IsFrozen() bool {
	return frozen
}

func Unfreeze(cur realm) {
	frozen = false
}

func GetListLimit() int {
	return listLimit
}

func GetBatchLimit() int {
	return batchLimit
}

func GetPermission(name string) map[string]string {
	if !chunkAuthzRBAC.HasPermission(name) {
		return nil
	}
	permission := chunkAuthzRBAC.GetPermission(name)
	return map[string]string{
		"name":        permission.Name,
		"description": permission.Description,
	}
}

func GetRoleInfo(roleName string) map[string]string {
	if !chunkAuthzRBAC.HasRole(roleName) {
		return nil
	}
	role := chunkAuthzRBAC.GetRole(roleName)
	info := copyStringMap(role.Metadata)
	info["name"] = role.Name
	return info
}

func ListGrantables(granterRole string, page int, count int) []string {
	if !chunkAuthzRBAC.HasRole(granterRole) {
		return []string{}
	}
	return chunkAuthzRBAC.ListGrantableRoles(granterRole, page, count)
}

func GrantRole(cur realm, tokenID grc721.TokenID, roleName string, user address) {
	if _, found := nftStore.OwnerOfSafe(tokenID); !found {
		panic("token not found: " + string(tokenID))
	}
	chunkAuthzRBAC.AssignRole(tokenID.String(), user, roleName)
}

func RevokeRole(cur realm, tokenID grc721.TokenID, roleName string, user address) {
	if _, found := nftStore.OwnerOfSafe(tokenID); !found {
		panic("token not found: " + string(tokenID))
	}
	chunkAuthzRBAC.UnassignRole(tokenID.String(), user, roleName)
}

func HasRole(tokenID grc721.TokenID, user address, roleName string) bool {
	if !chunkAuthzRBAC.HasRole(roleName) {
		return false
	}
	return chunkAuthzRBAC.HasUserRole(tokenID.String(), user, roleName)
}

func ListRoleGrants(tokenID grc721.TokenID, roleName string, page int, count int) []address {
	if !chunkAuthzRBAC.HasRole(roleName) {
		return []address{}
	}
	return chunkAuthzRBAC.ListRoleUsers(tokenID.String(), roleName, page, count)
}

func RevokeMaster(cur realm, worldID uint32, user address) {
	worldStore.AssertExists(worldID)
	worldAuthzRBAC.UnassignRole(formatWorldID(worldID), user, "master")
}

func IsMaster(worldID uint32, user address) bool {
	return worldAuthzRBAC.HasUserRole(formatWorldID(worldID), user, "master")
}

func buildChunkMetadataValue(worldType string, hash string) string {
	return worldType + metadataSeparator + hash
}

func buildMetadataResponse(row map[string]string) map[string]string {
	chunkKey := row["id"]
	value := row["metadata"]
	worldID, x, y := parseChunkKey(chunkKey)
	parts := strings.SplitN(value, metadataSeparator, 2)
	hash := ""
	if len(parts) > 1 {
		hash = parts[1]
	}
	return map[string]string{
		"id":        chunkKey,
		"worldId":   strconv.FormatUint(uint64(worldID), 10),
		"x":         strconv.Itoa(x),
		"y":         strconv.Itoa(y),
		"worldType": parts[0],
		"hash":      hash,
	}
}

func formatWorldID(worldID uint32) string {
	return strconv.FormatUint(uint64(worldID), 10)
}

func buildChunkKey(worldID uint32, x int, y int) string {
	return strconv.FormatUint(uint64(worldID), 10) + ":" + strconv.Itoa(x) + "_" + strconv.Itoa(y)
}

func parseChunkKey(chunkKey string) (uint32, int, int) {
	parts := strings.SplitN(chunkKey, ":", 2)
	if len(parts) != 2 {
		panic("invalid chunkKey format: " + chunkKey)
	}
	worldID, err := strconv.ParseUint(parts[0], 10, 32)
	if err != nil {
		panic("invalid worldID in chunkKey: " + chunkKey)
	}
	coords := strings.SplitN(parts[1], "_", 2)
	if len(coords) != 2 {
		panic("invalid coordinates in chunkKey: " + chunkKey)
	}
	x, errX := strconv.Atoi(coords[0])
	if errX != nil {
		panic("invalid x in chunkKey: " + chunkKey)
	}
	y, errY := strconv.Atoi(coords[1])
	if errY != nil {
		panic("invalid y in chunkKey: " + chunkKey)
	}
	return uint32(worldID), x, y
}

func normalizeChunkKey(worldID uint32, chunkKey string) string {
	parsedWorldID, x, y := parseChunkKey(chunkKey)
	if parsedWorldID != worldID {
		panic("chunkKey worldID mismatch: expected " + formatWorldID(worldID) + ", got " + formatWorldID(parsedWorldID))
	}
	return buildChunkKey(worldID, x, y)
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
