package block

import (
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/grc1155"
	oldblock "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/block"
)

type BlockStore = oldblock.BlockStore
type InstalledBlockStore = oldblock.InstalledBlockStore
type MintedBlockStore = oldblock.MintedBlockStore

var (
	blockStore          *BlockStore
	installedBlockStore *InstalledBlockStore
	mintedBlockStore    *MintedBlockStore
	creatorBPS          int
	listLimit           int
	frozen              bool
)

func GetTotalBlockSize() int {
	return blockStore.Total()
}

func IsFrozen() bool {
	return frozen
}

func Unfreeze(cur realm) {
	frozen = false
}

func GetCreatorBPS() int {
	return creatorBPS
}

func GetListLimit() int {
	return listLimit
}

func ListBlocksByIDs(blockIDs ...uint32) []map[string]string {
	return blockStore.ListByIDs(blockIDs...)
}

func GetBlockByName(name string) map[string]string {
	return blockStore.MustGetByName(name)
}

func GetBlockMetadata(blockID uint32) string {
	return blockStore.GetBlockMetadata(blockID)
}

func SetBlockMetadata(cur realm, blockID uint32, metadata string) {
	blockStore.SetMetadata(blockID, metadata)
}

func CreateBlock(cur realm, propKeys string, propValues string) uint32 {
	props := migrationResearchProperties(propKeys, propValues)
	props["creator"] = cur.Previous().Address().String()
	return blockStore.Create(props)
}

func BalanceOf(user address, tokenID grc1155.TokenID) int64 {
	return mintedBlockStore.BalanceOf(user, tokenID)
}

func Mint(cur realm, to address, blockID uint32, amount int64) {
	if amount < 1 {
		panic("amount must be positive")
	}
	block := blockStore.MustGet(blockID)
	maxSupply := migrationResearchMintableSupply(block)
	mintedBlockStore.Mint(to, to, blockIDToTokenID(blockID), amount, maxSupply)
}

func GetInventory(user address) []map[string]string {
	return mintedBlockStore.GetInventory(user)
}

func SetMintAllowlist(cur realm, blockID uint32, minters string) {
	blockStore.MustGet(blockID)
	mintedBlockStore.SetMintAllowlist(blockID, migrationResearchAddressCSV(minters))
}

func GetMintAllowlist(blockID uint32) []string {
	return mintedBlockStore.GetMintAllowlist(blockID)
}

func IsAcrRewardEnabled(blockID uint32) bool {
	return blockStore.IsAcrRewardEnabled(blockID)
}

func ListInstalled(positions ...string) []map[string]string {
	return installedBlockStore.ListInstalled(positions...)
}

func Read(position string) string {
	info, found := installedBlockStore.GetInstalled(position)
	if !found {
		panic("block not found at position: " + position)
	}
	return info["content"]
}

func Use(cur realm, position string) {
	info, found := installedBlockStore.GetInstalled(position)
	if !found {
		panic("block not found at position: " + position)
	}
	user := migrationResearchPositionOwner(position)
	block := blockStore.MustGet(stringToBlockID(info["blockId"]))
	installedBlockStore.RecordUse(user, map[string]string{
		"position":          position,
		"blockId":           info["blockId"],
		"user":              user.String(),
		"fee":               block["usePrice"],
		"installer":         info["installer"],
		"installerShare":    "0",
		"feeCollector":      "",
		"feeCollectorShare": "0",
	})
}

func ListUseLogs(user address, limit int) []map[string]string {
	return installedBlockStore.ListUseLogs(user, limit)
}

func blockIDToString(blockID uint32) string {
	return strconv.FormatUint(uint64(blockID), 10)
}

func stringToBlockID(blockIDStr string) uint32 {
	value, err := strconv.ParseUint(blockIDStr, 10, 32)
	if err != nil {
		panic("invalid blockID: " + err.Error())
	}
	return uint32(value)
}

func blockIDToTokenID(blockID uint32) grc1155.TokenID {
	return grc1155.TokenID(blockIDToString(blockID))
}

func migrationResearchMintableSupply(block map[string]string) int64 {
	maxSupply, err := strconv.ParseInt(block["maxSupply"], 10, 64)
	if err != nil {
		panic("maxSupply must be int")
	}
	if maxSupply < 0 {
		panic("block not mintable")
	}
	return maxSupply
}

func migrationResearchPositionOwner(position string) address {
	parts := strings.Split(position, "|")
	if len(parts) != 6 {
		panic("invalid position format: " + position)
	}
	return address(parts[2])
}

func migrationResearchAddressCSV(value string) []address {
	if value == "" {
		return []address{}
	}
	items := strings.Split(value, ",")
	result := []address{}
	for _, item := range items {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		result = append(result, address(item))
	}
	return result
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
