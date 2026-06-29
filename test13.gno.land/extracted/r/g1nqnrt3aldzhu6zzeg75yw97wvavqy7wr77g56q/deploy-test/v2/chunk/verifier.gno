package chunk

// This file manages chunk data for integrity verification.
// Verifier storage: BTree(worldID -> *BTree(chunkKey -> verifier)).

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

// ==================== Chunk Verifier ====================

// SetChunkVerifier stores verifier for a specific chunk key of a world.
func SetChunkVerifier(cur realm, worldID uint32, chunkKey string, verifier string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)

	canonicalChunkKey := normalizeChunkKey(worldID, chunkKey)
	verifierStore.Set(worldID, canonicalChunkKey, verifier)
}

// SetChunkVerifiers sets multiple chunk verifiers at once using direct string traversal.
// chunkKeys and verifiers are comma-separated strings with matching item counts.
// Example: chunkKeys="100000002:0_0,100000002:0_1", verifiers="a1b2c3d4,e5f6a7b8"
func SetChunkVerifiers(cur realm, worldID uint32, chunkKeys string, verifiers string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)

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

		if val == "" {
			panic("empty verifier not allowed")
		}

		// Keep this loop streaming. Building temporary []string values for every
		// key/verifier pair increases gas sharply on large batch calls.
		count++
		assertBatchLimit("chunkKeys", count)
		canonicalChunkKey := normalizeChunkKey(worldID, key)
		verifierStore.Set(worldID, canonicalChunkKey, val)

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

// GetChunkVerifier retrieves verifier for a specific chunk key of a world.
func GetChunkVerifier(worldID uint32, chunkKey string) string {
	assertMigrationStateAvailable()
	canonicalChunkKey := normalizeChunkKey(worldID, chunkKey)
	verifier, found := verifierStore.Get(worldID, canonicalChunkKey)
	if !found {
		return ""
	}
	return verifier
}

// ListChunkVerifiers retrieves verifiers for multiple chunk keys of a world.
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
