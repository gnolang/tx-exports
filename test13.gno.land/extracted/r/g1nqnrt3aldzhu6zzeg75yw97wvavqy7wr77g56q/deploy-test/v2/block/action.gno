package block

import (
	"strconv"
	"strings"

	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/grc721"

	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/chunk"
	personalworld "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/personal_world"
)

const (
	BlockInstalledEvent   = "BlockInstalled"
	BlockUninstalledEvent = "BlockUninstalled"
	BlockUsedEvent        = "BlockUsed"
)

func Install(cur realm, position string, blockID uint32, propKeys string, propValues string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	positionType, storeKey, coordKey, blockIndexKey := parsePosition(position)

	props := parseOptPropsCSV(propKeys, propValues)
	installValidator.MustValidate(props)

	if !hasInstallPermission(caller, positionType, storeKey, coordKey) {
		panic("unauthorized: no permission to install block in this world")
	}
	if installedBlockStore.HasInstalled(positionType, storeKey, coordKey, blockIndexKey) {
		panic("block already installed at position")
	}

	block := blockStore.MustGet(blockID)
	tokenID := blockIDToTokenID(blockID)
	if mintedBlockStore.BalanceOf(caller, tokenID) < 1 {
		panic("insufficient block balance: block " + string(tokenID) + " requires at least 1")
	}

	// installValidator rejects these keys before canonical block-owned fields
	// are injected, so clients cannot override identity, installer, shape, or state.
	props["blockId"] = string(tokenID)
	props["installer"] = caller.String()
	props["shape"] = block["shape"]
	props["state"] = block["state"]

	mintedBlockStore.Burn(caller, caller, tokenID, 1)
	installedBlockStore.SaveInstalled(positionType, storeKey, coordKey, blockIndexKey, props)

	chain.Emit(BlockInstalledEvent,
		"position", position,
		"blockId", props["blockId"],
		"installer", props["installer"],
	)
}

func Uninstall(cur realm, position string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	positionType, storeKey, coordKey, blockIndexKey := parsePosition(position)

	if !hasUninstallPermission(caller, positionType, storeKey, coordKey) {
		panic("unauthorized: no permission to uninstall block in this world")
	}
	if _, found := installedBlockStore.GetInstalled(positionType, storeKey, coordKey, blockIndexKey); !found {
		panic("block not found at position: " + position)
	}

	installedBlockStore.RemoveInstalled(positionType, storeKey, coordKey, blockIndexKey)

	chain.Emit(BlockUninstalledEvent,
		"position", position,
	)
}

func Read(position string) string {
	assertMigrationStateAvailable()
	positionType, storeKey, coordKey, blockIndexKey := parsePosition(position)
	info, found := installedBlockStore.GetInstalled(positionType, storeKey, coordKey, blockIndexKey)
	if !found {
		panic("block not found at position: " + position)
	}
	return info["content"]
}

func Use(cur realm, position string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	positionType, storeKey, coordKey, blockIndexKey := parsePosition(position)

	info, found := installedBlockStore.GetInstalled(positionType, storeKey, coordKey, blockIndexKey)
	if !found {
		panic("block not found at position: " + position)
	}

	blockID := stringToBlockID(info["blockId"])
	block := blockStore.MustGet(blockID)
	usePrice := int64(mustParseUint32(block["usePrice"]))
	installerBPS := int(mustParseUint32(block["installerBps"]))

	// MustGetUserCaller guarantees a direct user call, so OriginSend cannot be borrowed through an intermediate realm.
	payment := unsafe.OriginSend().AmountOf("ugnot")
	assertExactPayment(usePrice, payment)

	feeCollector := admin.GetFeeCollector()
	installerShare, feeCollectorShare := distributeShares(cur, info["installer"], feeCollector, payment, installerBPS)

	useLog := map[string]string{
		"position":          position,
		"blockId":           info["blockId"],
		"user":              caller.String(),
		"fee":               block["usePrice"],
		"installer":         info["installer"],
		"installerShare":    strconv.FormatInt(installerShare, 10),
		"feeCollector":      feeCollector.String(),
		"feeCollectorShare": strconv.FormatInt(feeCollectorShare, 10),
	}

	result := installedBlockStore.RecordUse(caller, useLog)

	chain.Emit(BlockUsedEvent,
		"logId", result["id"],
		"position", position,
		"blockId", useLog["blockId"],
		"user", useLog["user"],
		"fee", result["fee"],
	)
}

// ListInstalled returns installed blocks for given positions
// position format: "{type}|{worldId}|{owner}|{xIndex}|{zIndex}|{blockIndex}"
func ListInstalled(positions ...string) []map[string]string {
	assertMigrationStateAvailable()
	result := []map[string]string{}
	for _, position := range positions {
		positionType, storeKey, coordKey, blockIndexKey := parsePosition(position)
		if info, found := installedBlockStore.GetInstalled(positionType, storeKey, coordKey, blockIndexKey); found {
			result = append(result, info)
		}
	}
	return result
}

// ListUseLogs returns user's block use logs (newest first, limited)
func ListUseLogs(user address, limit int) []map[string]string {
	assertMigrationStateAvailable()
	return installedBlockStore.ListUseLogs(user, limit)
}

func logIDToString(logID uint64) string {
	return strconv.FormatUint(logID, 10)
}

// Position is the public install key:
//
//	personal|{worldId}|{owner}|{xIndex}|{zIndex}|{blockIndex}
//	system|{chunkId}|{owner}|{xIndex}|{zIndex}|{blockIndex}
//
// Storage uses the world/chunk id as the top-level key, x/z as the coordinate
// key, and blockIndex as the installed block key. Permission checks derive the
// target world from the same string: personal uses worldId, system uses
// chunkId:xIndex_zIndex. The owner segment is part of the client-facing key,
// but it is not the authority source.
// parsePosition parses position into storage key components.
// Format: "type|worldId|owner|xIndex|zIndex|blockIndex"
// Returns: (positionType, storeKey, coordKey, blockIndexKey)
func parsePosition(position string) (positionType string, storeKey string, coordKey string, blockIndexKey string) {
	parts := strings.Split(position, "|")
	if len(parts) != 6 {
		panic("invalid position format: must be 'type|worldId|owner|xIndex|zIndex|blockIndex'")
	}

	positionType = parts[0]
	if positionType != "personal" && positionType != "system" {
		panic("unknown position type: " + position)
	}
	storeKey = parts[1]
	coordKey = parts[3] + "_" + parts[4]
	blockIndexKey = parts[5]
	return positionType, storeKey, coordKey, blockIndexKey
}

func isPersonalWorld(position string) bool {
	return strings.HasPrefix(position, "personal|")
}

func isSystemChunk(position string) bool {
	return strings.HasPrefix(position, "system|")
}

// extractPersonalWorldID expects: personal|{worldId}|{owner}|{xIndex}|{zIndex}|{blockIndex}
func extractPersonalWorldID(position string) uint32 {
	if !isPersonalWorld(position) {
		panic("not a personal world position: " + position)
	}

	_, storeKey, _, _ := parsePosition(position)
	id, err := strconv.ParseUint(storeKey, 10, 32)
	if err != nil {
		panic("invalid world ID: " + storeKey)
	}
	return uint32(id)
}

// extractSystemChunkID expects: system|{chunkId}|{owner}|{xIndex}|{zIndex}|{blockIndex}
func extractSystemChunkID(position string) string {
	if !isSystemChunk(position) {
		panic("not a system chunk position: " + position)
	}

	_, storeKey, coordKey, _ := parsePosition(position)
	return storeKey + ":" + coordKey
}

func HasInstalled(position string) bool {
	assertMigrationStateAvailable()
	positionType, storeKey, coordKey, blockIndexKey := parsePosition(position)
	return installedBlockStore.HasInstalled(positionType, storeKey, coordKey, blockIndexKey)
}

func hasInstallPermission(caller address, positionType string, storeKey string, coordKey string) bool {
	if positionType == "personal" {
		worldID := mustParsePositionWorldID(storeKey)
		return personalworld.HasInstallPermission(worldID, caller)
	}

	if positionType == "system" {
		tokenID := grc721.TokenID(storeKey + ":" + coordKey)
		return chunk.HasInstallPermission(tokenID, caller)
	}

	return false
}

func hasUninstallPermission(caller address, positionType string, storeKey string, coordKey string) bool {
	if positionType == "personal" {
		worldID := mustParsePositionWorldID(storeKey)
		return personalworld.HasUninstallPermission(worldID, caller)
	}

	if positionType == "system" {
		tokenID := grc721.TokenID(storeKey + ":" + coordKey)
		return chunk.HasUninstallPermission(tokenID, caller)
	}

	return false
}

func mustParsePositionWorldID(storeKey string) uint32 {
	id, err := strconv.ParseUint(storeKey, 10, 32)
	if err != nil {
		panic("invalid world ID: " + storeKey)
	}
	return uint32(id)
}
