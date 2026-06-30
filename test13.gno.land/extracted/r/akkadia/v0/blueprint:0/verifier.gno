package blueprint

import (
	"chain"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/r/akkadia/v0/admin"
)

const SetChunkVerifierEvent = "SetChunkVerifier"

// SetChunkVerifier stores verifier for a specific chunk key of a blueprint.
func SetChunkVerifier(cur realm, blueprintID uint32, chunkKey string, verifier string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)
	blueprintStore.AssertBlueprintExists(blueprintID)
	assertChunkKey(chunkKey)

	verifierStore.Set(blueprintID, chunkKey, verifier)

	chain.Emit(
		SetChunkVerifierEvent,
		"id", formatBlueprintID(blueprintID),
		"chunkKey", chunkKey,
	)
}

// SetChunkVerifiers sets multiple chunk verifiers at once using direct string traversal.
// chunkKeys and verifiers are comma-separated strings with matching item counts.
func SetChunkVerifiers(cur realm, blueprintID uint32, chunkKeys string, verifiers string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)
	blueprintStore.AssertBlueprintExists(blueprintID)

	if chunkKeys == "" {
		panic("chunkKeys must not be empty")
	}
	if verifiers == "" {
		panic("verifiers must not be empty")
	}

	keyStart, valStart := 0, 0
	keyIdx, valIdx := 0, 0
	count := 0

	for {
		for keyIdx < len(chunkKeys) && chunkKeys[keyIdx] != ',' {
			keyIdx++
		}
		for valIdx < len(verifiers) && verifiers[valIdx] != ',' {
			valIdx++
		}

		key := chunkKeys[keyStart:keyIdx]
		val := verifiers[valStart:valIdx]
		if key == "" {
			panic("empty chunkKey not allowed")
		}
		if val == "" {
			panic("empty verifier not allowed")
		}

		count++
		assertBatchLimit("chunkKeys", count)
		assertChunkKey(key)
		verifierStore.Set(blueprintID, key, val)

		keyEnd := keyIdx >= len(chunkKeys)
		valEnd := valIdx >= len(verifiers)
		if keyEnd != valEnd {
			panic("chunkKeys and verifiers count mismatch")
		}
		if keyEnd {
			break
		}

		keyIdx++
		valIdx++
		keyStart = keyIdx
		valStart = valIdx
	}
}

// GetChunkVerifier retrieves verifier for a specific chunk key of a blueprint.
func GetChunkVerifier(blueprintID uint32, chunkKey string) string {
	assertMigrationStateAvailable()
	blueprintStore.AssertBlueprintExists(blueprintID)
	assertChunkKey(chunkKey)
	verifier, found := verifierStore.Get(blueprintID, chunkKey)
	if !found {
		return ""
	}
	return verifier
}

// ListChunkVerifiers retrieves verifiers for multiple chunk keys of a blueprint.
func ListChunkVerifiers(blueprintID uint32, chunkKeys ...string) []map[string]string {
	assertMigrationStateAvailable()
	blueprintStore.AssertBlueprintExists(blueprintID)
	assertListLimit("chunkKeys", len(chunkKeys))
	result := []map[string]string{}
	for _, chunkKey := range chunkKeys {
		assertChunkKey(chunkKey)
		verifier, found := verifierStore.Get(blueprintID, chunkKey)
		if found {
			result = append(result, map[string]string{
				"chunkKey": chunkKey,
				"verifier": verifier,
			})
		}
	}
	return result
}
