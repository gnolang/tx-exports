package block

import (
	"strconv"
	"strings"

	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/grc721"

	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/chunk"
	personalworld "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/personal_world"
)

const (
	BlockInstalledEvent   = "BlockInstalled"
	BlockUninstalledEvent = "BlockUninstalled"
	BlockUsedEvent        = "BlockUsed"
)

func Install(cur realm, position string, blockID uint32, propKeys string, propValues string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)

	props := parseOptPropsCSV(propKeys, propValues)
	installValidator.MustValidate(props)

	if !hasInstallPermission(caller, position) {
		panic("unauthorized: no permission to install block in this world")
	}
	if installedBlockStore.HasInstalled(position) {
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
	installedBlockStore.SaveInstalled(
		position,
		props,
	)

	chain.Emit(BlockInstalledEvent,
		"position", position,
		"blockId", props["blockId"],
		"installer", props["installer"],
	)
}

func Uninstall(cur realm, position string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)

	if !hasUninstallPermission(caller, position) {
		panic("unauthorized: no permission to uninstall block in this world")
	}
	if _, found := installedBlockStore.GetInstalled(position); !found {
		panic("block not found at position: " + position)
	}

	installedBlockStore.RemoveInstalled(position)

	chain.Emit(BlockUninstalledEvent,
		"position", position,
	)
}

func Read(position string) string {
	assertMigrationStateAvailable()
	info, found := installedBlockStore.GetInstalled(position)
	if !found {
		panic("block not found at position: " + position)
	}
	return info["content"]
}

func Use(cur realm, position string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)

	info, found := installedBlockStore.GetInstalled(position)
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
	return installedBlockStore.ListInstalled(positions...)
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
// Returns: (storeKey, coordKey, blockIndexKey)
func parsePosition(position string) (storeKey string, coordKey string, blockIndexKey string) {
	parts := strings.Split(position, "|")
	if len(parts) != 6 {
		panic("invalid position format: must be 'type|worldId|owner|xIndex|zIndex|blockIndex'")
	}

	storeKey = parts[1]
	coordKey = parts[3] + "_" + parts[4]
	blockIndexKey = parts[5]
	return storeKey, coordKey, blockIndexKey
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

	parts := strings.Split(position, "|")
	if len(parts) != 6 {
		panic("invalid position format: " + position)
	}

	id, err := strconv.ParseUint(parts[1], 10, 32)
	if err != nil {
		panic("invalid world ID: " + parts[1])
	}
	return uint32(id)
}

// extractSystemChunkID expects: system|{chunkId}|{owner}|{xIndex}|{zIndex}|{blockIndex}
func extractSystemChunkID(position string) string {
	if !isSystemChunk(position) {
		panic("not a system chunk position: " + position)
	}

	parts := strings.Split(position, "|")
	if len(parts) != 6 {
		panic("invalid position format: " + position)
	}

	return parts[1] + ":" + parts[3] + "_" + parts[4]
}

func HasInstalled(position string) bool {
	assertMigrationStateAvailable()
	return installedBlockStore.HasInstalled(position)
}

func hasInstallPermission(caller address, position string) bool {
	if isPersonalWorld(position) {
		worldID := extractPersonalWorldID(position)
		return personalworld.HasInstallPermission(worldID, caller)
	}

	if isSystemChunk(position) {
		tokenID := grc721.TokenID(extractSystemChunkID(position))
		return chunk.HasInstallPermission(tokenID, caller)
	}

	return false
}

func hasUninstallPermission(caller address, position string) bool {
	if isPersonalWorld(position) {
		worldID := extractPersonalWorldID(position)
		return personalworld.HasUninstallPermission(worldID, caller)
	}

	if isSystemChunk(position) {
		tokenID := grc721.TokenID(extractSystemChunkID(position))
		return chunk.HasUninstallPermission(tokenID, caller)
	}

	return false
}
