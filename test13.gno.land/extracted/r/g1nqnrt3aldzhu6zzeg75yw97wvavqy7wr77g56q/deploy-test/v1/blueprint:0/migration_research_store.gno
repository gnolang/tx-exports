package blueprint

import (
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/validate"
	oldbp "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/blueprint"
)

type BlueprintStore = oldbp.BlueprintStore
type VerifierStore = oldbp.VerifierStore

const (
	MigrationResearchExpectedBiome      = "everdawn_plains"
	MigrationResearchExpectedState      = "draft"
	MigrationResearchExpectedMetadata   = `{"source":"migration-research"}`
	MigrationResearchExpectedChunkKey   = "0:0_0"
	MigrationResearchExpectedVerifier   = "migration_research_verifier"
	MigrationResearchExpectedNamePrefix = "MRBP_"
)

var (
	blueprintStore           *BlueprintStore
	verifierStore            *VerifierStore
	blueprintCreateValidator *validate.Validator
	blueprintUpdateValidator *validate.Validator
	creationCost             int64
	listLimit                int
	batchLimit               int
	frozen                   bool
)

func CreateBlueprint(cur realm, propKeys string, propValues string) uint32 {
	props := migrationResearchProperties(propKeys, propValues)
	blueprintCreateValidator.MustValidate(props)
	id := blueprintStore.NextID()
	props["id"] = formatBlueprintID(id)
	props["owner"] = cur.Previous().Address().String()
	props["createdAt"] = defaultString(props["createdAt"], "0")
	props["updatedAt"] = defaultString(props["updatedAt"], "0")
	return blueprintStore.Create(props)
}

func UpdateBlueprint(cur realm, blueprintID uint32, propKeys string, propValues string) {
	current := copyStringMap(blueprintStore.MustGet(blueprintID))
	props := migrationResearchProperties(propKeys, propValues)
	for key, value := range props {
		current[key] = value
	}
	current["updatedAt"] = "0"
	blueprintUpdateValidator.MustValidate(props)
	blueprintStore.Update(blueprintID, current)
}

func DeleteBlueprint(cur realm, blueprintID uint32) {
	blueprintStore.Delete(blueprintID)
	verifierStore.Delete(blueprintID)
}

func SetBlueprintMetadata(cur realm, blueprintID uint32, metadata string) {
	blueprintStore.SetMetadata(blueprintID, metadata)
}

func GetBlueprintMetadata(blueprintID uint32) string {
	return blueprintStore.GetMetadata(blueprintID)
}

func GetBlueprint(blueprintID uint32) map[string]string {
	return blueprintStore.MustGet(blueprintID)
}

func GetBlueprintIDByName(name string) uint32 {
	return blueprintStore.MustGetIDByName(name)
}

func GetTotalBlueprintSize() int {
	return blueprintStore.Total()
}

func IsNameAvailable(name string) bool {
	return blueprintStore.IsNameAvailable(name)
}

func GetBlueprintSizeByOwner(owner address) int {
	return blueprintStore.OwnerCount(owner)
}

func GetBlueprintSizeByBiome(biomeName string) int {
	return blueprintStore.BiomeCount(biomeName)
}

func GetBlueprintSizeByBiomeState(biomeName string, state string) int {
	return blueprintStore.BiomeStateCount(biomeName, state)
}

func SetChunkVerifier(cur realm, blueprintID uint32, chunkKey string, verifier string) {
	blueprintStore.AssertBlueprintExists(blueprintID)
	verifierStore.Set(blueprintID, chunkKey, verifier)
}

func GetChunkVerifier(blueprintID uint32, chunkKey string) string {
	verifier, found := verifierStore.Get(blueprintID, chunkKey)
	if !found {
		return ""
	}
	return verifier
}

func Unfreeze(cur realm) {
	frozen = false
}

func IsFrozen() bool {
	return frozen
}

func GetCreationCost() int64 {
	return creationCost
}

func GetListLimit() int {
	return listLimit
}

func GetBatchLimit() int {
	return batchLimit
}

func formatBlueprintID(blueprintID uint32) string {
	return strconv.FormatUint(uint64(blueprintID), 10)
}

func migrationResearchProperties(keys string, values string) map[string]string {
	if keys == "" {
		panic("properties keys must be not empty")
	}
	keyParts := strings.Split(keys, ",")
	valueParts := strings.Split(values, ",")
	if len(keyParts) != len(valueParts) {
		panic("properties keys and values count mismatch")
	}

	props := map[string]string{}
	for i, key := range keyParts {
		if key == "" {
			panic("properties key must be not empty")
		}
		props[key] = valueParts[i]
	}
	return props
}

func defaultString(value string, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func copyStringMap(source map[string]string) map[string]string {
	result := make(map[string]string)
	for key, value := range source {
		result[key] = value
	}
	return result
}
