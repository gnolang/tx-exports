package chunk

import (
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/grc721"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const metadataSeparator = "|"

// ==================== GRC-721 ====================

func Name() string {
	assertMigrationStateAvailable()
	return nftStore.Name()
}

func Symbol() string {
	assertMigrationStateAvailable()
	return nftStore.Symbol()
}

func TokenCount() int64 {
	assertMigrationStateAvailable()
	return nftStore.TokenCount()
}

func BalanceOf(user address) int64 {
	assertMigrationStateAvailable()
	balance, err := nftStore.BalanceOf(user)
	if err != nil {
		panic("balanceOf failed: " + err.Error())
	}

	return balance
}

func OwnerOf(tokenID grc721.TokenID) address {
	assertMigrationStateAvailable()
	owner, found := nftStore.OwnerOfSafe(tokenID)
	if !found {
		_, err := nftStore.OwnerOf(tokenID)
		panic("ownerOf failed: " + err.Error())
	}

	return owner
}

func IsApprovedForAll(owner, user address) bool {
	assertMigrationStateAvailable()
	return nftStore.IsApprovedForAll(owner, user)
}

func GetApproved(tokenID grc721.TokenID) address {
	assertMigrationStateAvailable()
	addr, err := nftStore.GetApproved(tokenID)
	if err != nil {
		panic("getApproved failed: " + err.Error())
	}

	return addr
}

func Approve(cur realm, user address, tokenID grc721.TokenID) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	err := nftStore.Approve(caller, user, tokenID)
	if err != nil {
		panic("approve failed: " + err.Error())
	}
}

func SetApprovalForAll(cur realm, user address, approved bool) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	err := nftStore.SetApprovalForAll(caller, user, approved)
	if err != nil {
		panic("setApprovalForAll failed: " + err.Error())
	}
}

func TransferFrom(cur realm, from, to address, tokenID grc721.TokenID) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	worldID, _, _ := parseChunkKey(string(tokenID))
	err := nftStore.Transfer(caller, from, to, tokenID, worldID)
	if err != nil {
		panic("transferFrom failed: " + err.Error())
	}

	chunkAuthzRBAC.DeleteEntity(tokenID.String())
}

func Mint(cur realm, to address, worldType string, worldID uint32, x, y int, chunkHashKey string, chunkVerifier string) grc721.TokenID {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)
	worldStore.AssertExists(worldID)

	chunkKey := buildChunkKey(worldID, x, y)
	tokenID := grc721.TokenID(chunkKey)
	metadata := buildChunkMetadataValue(worldType, chunkHashKey)
	err := nftStore.Mint(to, tokenID, worldID, metadata)
	if err != nil {
		panic("mint failed for " + chunkKey + ": " + err.Error())
	}

	if chunkVerifier != "" {
		verifierStore.Set(worldID, chunkKey, chunkVerifier)
	}

	return tokenID
}

func MintBatch(cur realm, to address, worldType string, worldID uint32, xs string, ys string, chunkHashKeys string, chunkVerifiers string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)
	worldStore.AssertExists(worldID)

	if xs == "" {
		panic("xs must not be empty")
	}
	if ys == "" {
		panic("ys must not be empty")
	}
	if chunkHashKeys == "" {
		panic("chunkHashKeys must not be empty")
	}

	xStart, yStart, hStart, vStart := 0, 0, 0, 0
	xIdx, yIdx, hIdx, vIdx := 0, 0, 0, 0

	// Stream each parsed row directly into storage instead of first appending all
	// rows to temporary slices. Large batch mints are gas sensitive, and Gno
	// transaction rollback preserves atomicity if a later row panics.
	for {
		for xIdx < len(xs) && xs[xIdx] != ',' {
			xIdx++
		}
		for yIdx < len(ys) && ys[yIdx] != ',' {
			yIdx++
		}
		for hIdx < len(chunkHashKeys) && chunkHashKeys[hIdx] != ',' {
			hIdx++
		}
		for vIdx < len(chunkVerifiers) && chunkVerifiers[vIdx] != ',' {
			vIdx++
		}

		x := xs[xStart:xIdx]
		y := ys[yStart:yIdx]
		hashKey := chunkHashKeys[hStart:hIdx]
		verifier := ""
		if vStart <= vIdx && vIdx <= len(chunkVerifiers) {
			verifier = chunkVerifiers[vStart:vIdx]
		}

		if x == "" {
			panic("empty x not allowed")
		}
		if y == "" {
			panic("empty y not allowed")
		}
		if hashKey == "" {
			panic("empty key not allowed")
		}

		xInt, errX := strconv.Atoi(x)
		if errX != nil {
			panic("invalid x: " + x)
		}
		yInt, errY := strconv.Atoi(y)
		if errY != nil {
			panic("invalid y: " + y)
		}

		xEnd := xIdx >= len(xs)
		yEnd := yIdx >= len(ys)
		hEnd := hIdx >= len(chunkHashKeys)
		if xEnd != yEnd || xEnd != hEnd {
			panic("xs, ys and haskeys count mismatch")
		}

		chunkKey := buildChunkKey(worldID, xInt, yInt)
		tokenID := grc721.TokenID(chunkKey)
		metadata := buildChunkMetadataValue(worldType, hashKey)
		err := nftStore.Mint(to, tokenID, worldID, metadata)
		if err != nil {
			panic("mint failed for " + chunkKey + ": " + err.Error())
		}

		if verifier != "" {
			verifierStore.Set(worldID, chunkKey, verifier)
		}

		if xEnd {
			break
		}

		xIdx++
		yIdx++
		hIdx++
		vIdx++
		xStart = xIdx
		yStart = yIdx
		hStart = hIdx
		vStart = vIdx
	}
}

func Burn(cur realm, tokenID grc721.TokenID) {
	assertNotFrozen()
	panic("burn not supported for chunk tokens")
}

func ListOwners(tokenIDs ...grc721.TokenID) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("tokenIDs", len(tokenIDs))
	return nftStore.ListOwners(tokenIDs...)
}

// ==================== Metadata ====================

func SetChunkMetadata(cur realm, worldType string, worldID uint32, x, y int32, hash string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)
	worldStore.AssertExists(worldID)
	tokenID := grc721.TokenID(buildChunkKey(worldID, int(x), int(y)))
	metadata := buildChunkMetadataValue(worldType, hash)
	nftStore.SetChunkMetadata(worldID, tokenID, metadata)
}

func GetChunkMetadata(chunkKey string) map[string]string {
	assertMigrationStateAvailable()
	worldID, _, _ := parseChunkKey(chunkKey)
	row := nftStore.GetChunkMetadata(worldID, grc721.TokenID(chunkKey))
	if row == nil {
		return nil
	}
	return buildMetadataResponse(row)
}

func GetChunkMetadataSizeByWorld(worldID uint32) int {
	assertMigrationStateAvailable()
	return nftStore.WorldMetadataSize(worldID)
}

// ListChunkMetadataByKeys retrieves metadata for specific chunk keys.
// Each key format: "worldId:x_y" (same as tokenID).
func ListChunkMetadataByKeys(chunkKeys ...string) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("chunkKeys", len(chunkKeys))

	result := []map[string]string{}
	for _, chunkKey := range chunkKeys {
		worldID, _, _ := parseChunkKey(chunkKey)
		row := nftStore.GetChunkMetadata(worldID, grc721.TokenID(chunkKey))
		if row != nil {
			result = append(result, buildMetadataResponse(row))
		}
	}
	return result
}

func buildChunkMetadataValue(worldType string, hash string) string {
	// Keep the persisted chunk metadata as one encoded string for gas efficiency.
	// Public query helpers expand it back into a map-shaped response.
	return worldType + metadataSeparator + hash
}

func buildMetadataResponse(row map[string]string) map[string]string {
	chunkKey := row["id"]
	value := row["metadata"]
	worldID, x, y := parseChunkKey(chunkKey)

	parts := strings.SplitN(value, metadataSeparator, 2)
	worldType := parts[0]
	hash := ""
	if len(parts) > 1 {
		hash = parts[1]
	}

	return map[string]string{
		"id":        chunkKey,
		"worldId":   strconv.FormatUint(uint64(worldID), 10),
		"x":         strconv.Itoa(x),
		"y":         strconv.Itoa(y),
		"worldType": worldType,
		"hash":      hash,
	}
}

func ListChunkMetadataByWorld(worldID uint32, page int, count int) []map[string]string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	rows := nftStore.ListChunkMetadataByWorld(worldID, page, count)
	result := []map[string]string{}
	for _, row := range rows {
		result = append(result, buildMetadataResponse(row))
	}
	return result
}

// ==================== Owner Index ====================

// ListChunkKeysByOwner returns chunk keys owned by owner in page/count order.
func ListChunkKeysByOwner(worldID uint32, owner address, page, count int) []string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	return nftStore.ListTokenIDsByOwner(worldID, owner, page, count)
}

func GetOwnerTokenSize(worldID uint32, owner address) int {
	assertMigrationStateAvailable()
	return nftStore.OwnerTokenSize(worldID, owner)
}
