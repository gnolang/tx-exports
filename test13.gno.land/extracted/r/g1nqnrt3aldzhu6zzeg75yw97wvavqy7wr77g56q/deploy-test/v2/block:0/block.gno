package block

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
)

const (
	CreateBlockEvent = "CreateBlock"
)

func CreateBlock(cur realm, propKeys string, propValues string) uint32 {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)

	props := parsePropsCSV(propKeys, propValues)
	createValidator.MustValidate(props)
	assertBlockName(props["name"])
	maxSupply := mustParseUint32Field(props, "maxSupply")
	assertNormalMaxSupply(maxSupply)
	assertInstallerBPS(mustParseUint32Field(props, "installerBps"))
	props["creator"] = caller.String()
	blockID := blockStore.Create(props)
	blockIDStr := blockIDToString(blockID)
	creator := caller.String()

	chain.Emit(
		CreateBlockEvent,
		"id", blockIDStr,
		"name", props["name"],
		"creator", creator,
	)

	return blockID
}

func GetCurrentBlockID() uint32 {
	assertMigrationStateAvailable()
	return blockStore.NextID()
}

func GetTotalBlockSize() int {
	assertMigrationStateAvailable()
	return blockStore.Total()
}

func GetSystemBlockSize() int {
	assertMigrationStateAvailable()
	return blockStore.SystemTotal()
}

func GetNormalBlockSize() int {
	assertMigrationStateAvailable()
	return blockStore.NormalTotal()
}

func GetBlockByName(name string) map[string]string {
	assertMigrationStateAvailable()
	assertBlockName(name)
	return blockStore.MustGetByName(name)
}

func ListBlocks(page, count int) []map[string]string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)

	return blockStore.List(page, count)
}

func ListBlocksFromTo(from, to, limit uint32) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("limit", int(limit))

	if from > to {
		panic("from is greater than to")
	}

	var end *uint32
	if to < ^uint32(0) {
		endValue := to + 1
		end = &endValue
	}

	return blockStore.ListFromTo(&from, end, limit)
}

func ListBlocksByIDs(blockIDs ...uint32) []map[string]string {
	assertMigrationStateAvailable()
	assertListLimit("blockIDs", len(blockIDs))

	return blockStore.ListByIDs(blockIDs...)
}

func GetBlockMetadata(blockID uint32) string {
	assertMigrationStateAvailable()
	return blockStore.GetBlockMetadata(blockID)
}

func ListBlockMetadataByIDs(blockIDs ...uint32) []string {
	assertMigrationStateAvailable()
	assertListLimit("blockIDs", len(blockIDs))

	return blockStore.ListBlockMetadataByIDs(blockIDs...)
}
