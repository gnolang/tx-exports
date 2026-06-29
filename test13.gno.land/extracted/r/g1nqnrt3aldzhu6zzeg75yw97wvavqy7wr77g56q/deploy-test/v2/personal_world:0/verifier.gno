package personal_world

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

// SetChunkVerifier stores verifier for a specific chunk key of a world.
func SetChunkVerifier(cur realm, worldID uint32, chunkKey string, verifier string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)

	canonicalChunkKey := normalizeChunkKey(worldID, chunkKey)
	verifierStore.Set(worldID, canonicalChunkKey, verifier)
}

// SetChunkVerifiers sets multiple chunk verifiers at once using direct string traversal.
// chunkKeys and verifiers are comma-separated strings with matching item counts.
// Example: chunkKeys="1:0_0,1:0_1", verifiers="a1b2c3d4,e5f6a7b8"
func SetChunkVerifiers(cur realm, worldID uint32, chunkKeys string, verifiers string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)

	if chunkKeys == "" {
		panic("chunkKeys must not be empty")
	}
	if verifiers == "" {
		panic("verifiers must not be empty")
	}

	// Direct string traversal parsing (no strings.Split)
	keyStart, valStart := 0, 0
	keyIdx, valIdx := 0, 0
	count := 0

	for {
		// Find next delimiter or end for keys
		for keyIdx < len(chunkKeys) && chunkKeys[keyIdx] != ',' {
			keyIdx++
		}
		// Find next delimiter or end for values
		for valIdx < len(verifiers) && verifiers[valIdx] != ',' {
			valIdx++
		}

		// Extract key and value
		key := chunkKeys[keyStart:keyIdx]
		val := verifiers[valStart:valIdx]

		// Validate: no empty keys or values allowed
		if val == "" {
			panic("empty verifier not allowed")
		}

		count++
		assertBatchLimit("chunkKeys", count)
		canonicalChunkKey := normalizeChunkKey(worldID, key)
		verifierStore.Set(worldID, canonicalChunkKey, val)

		// Check end conditions
		keyEnd := keyIdx >= len(chunkKeys)
		valEnd := valIdx >= len(verifiers)

		// Validate: both must end at the same time (same item count)
		if keyEnd != valEnd {
			panic("chunkKeys and verifiers count mismatch")
		}
		if keyEnd {
			break
		}

		// Move past the delimiter
		keyIdx++
		valIdx++
		keyStart = keyIdx
		valStart = valIdx
	}
}

func GetChunkVerifier(worldID uint32, chunkKey string) string {
	assertMigrationStateAvailable()
	canonicalChunkKey := normalizeChunkKey(worldID, chunkKey)
	verifier, found := verifierStore.Get(worldID, canonicalChunkKey)
	if !found {
		return ""
	}
	return verifier
}

func ListChunkVerifiers(worldID uint32, chunkKeys ...string) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("chunkKeys", len(chunkKeys))
	result := []map[string]string{}
	for _, chunkKey := range chunkKeys {
		canonicalChunkKey := normalizeChunkKey(worldID, chunkKey)
		verifier, found := verifierStore.Get(worldID, canonicalChunkKey)
		if found {
			result = append(result, map[string]string{
				"chunkKey": canonicalChunkKey,
				"verifier": verifier,
			})
		}
	}
	return result
}
