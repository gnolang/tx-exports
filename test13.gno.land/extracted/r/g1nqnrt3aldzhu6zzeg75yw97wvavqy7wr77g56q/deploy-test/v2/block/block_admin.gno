package block

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

const (
	CreateSystemBlockEvent      = "CreateSystemBlock"
	AdminDeleteBlockEvent       = "AdminDeleteBlock"
	AdminDeleteSystemBlockEvent = "AdminDeleteSystemBlock"
	AdminUpdateBlockEvent       = "AdminUpdateBlock"
	SetBlockMetadataEvent       = "AdminSetMetadata"
)

func CreateSystemBlock(cur realm, blockID uint32, propKeys string, propValues string, metadata string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetAdminCaller(0, cur, admin.IsAdmin)

	props := parsePropsCSV(propKeys, propValues)
	createValidator.MustValidate(props)
	assertBlockName(props["name"])
	maxSupply := mustParseInt64Field(props, "maxSupply")
	assertSystemMaxSupply(maxSupply)
	assertInstallerBPS(mustParseUint32Field(props, "installerBps"))
	assertMetadata(metadata)

	blockIDStr := blockIDToString(blockID)
	creator := caller.String()
	props["creator"] = creator
	blockStore.CreateSystem(blockID, props)
	blockStore.SetMetadata(blockID, metadata)

	chain.Emit(
		CreateSystemBlockEvent,
		"id", blockIDStr,
		"name", props["name"],
		"creator", creator,
	)
}

func AdminDeleteBlock(cur realm, blockID uint32) {
	assertNotFrozen()
	caller := accesscontrol.MustGetAdminCaller(0, cur, admin.IsAdmin)

	if blockStore.IsSystemID(blockID) {
		panic("cannot delete system block: " + blockIDToString(blockID))
	}
	block := blockStore.MustGet(blockID)
	assertNoSupply(block)

	blockStore.Delete(blockID)
	mintedBlockStore.ClearMintAllowlist(blockID)

	chain.Emit(
		AdminDeleteBlockEvent,
		"id", blockIDToString(blockID),
		"caller", caller.String(),
	)
}

func AdminDeleteSystemBlock(cur realm, blockID uint32) {
	assertNotFrozen()
	caller := accesscontrol.MustGetAdminCaller(0, cur, admin.IsAdmin)

	if !blockStore.IsSystemID(blockID) {
		panic("not a system block: " + blockIDToString(blockID))
	}
	block := blockStore.MustGet(blockID)
	assertNoSupply(block)

	blockStore.Delete(blockID)
	mintedBlockStore.ClearMintAllowlist(blockID)

	chain.Emit(
		AdminDeleteSystemBlockEvent,
		"id", blockIDToString(blockID),
		"caller", caller.String(),
	)
}

func assertNoSupply(block map[string]string) {
	blockIDStr := block["id"]
	blockID := stringToBlockID(blockIDStr)
	maxSupply := mustParseInt64(block["maxSupply"])
	// Off-chain blocks (maxSupply == -1) are not minted, so they can bypass the
	// non-zero supply policy even when they use system block IDs.
	if maxSupply != -1 && mintedBlockStore.SupplyOf(blockID) != 0 {
		panic("cannot delete block with non-zero supply: " + blockIDStr)
	}
}

func AdminUpdateBlock(cur realm, blockID uint32, propKeys string, propValues string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	updates := parsePropsCSV(propKeys, propValues)
	updateValidator.MustValidate(updates)
	if name, found := updates["name"]; found {
		assertBlockName(name)
	}
	if maxSupply, found := updates["maxSupply"]; found {
		assertSystemMaxSupply(mustParseInt64(maxSupply))
	}
	if installerBPS, found := updates["installerBps"]; found {
		assertInstallerBPS(mustParseUint32(installerBPS))
	}
	blockStore.Update(blockID, updates)

	chain.Emit(
		AdminUpdateBlockEvent,
		"id", blockIDToString(blockID),
	)
}

func SetBlockMetadata(cur realm, blockID uint32, metadata string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertMetadata(metadata)

	blockStore.SetMetadata(blockID, metadata)

	chain.Emit(
		SetBlockMetadataEvent,
		"id", blockIDToString(blockID),
	)
}
