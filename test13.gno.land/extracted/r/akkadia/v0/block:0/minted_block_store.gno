package block

import (
	"strconv"

	"gno.land/p/akkadia/v0/ds/btree"
	"gno.land/p/akkadia/v0/ds/btreeset"
	"gno.land/p/akkadia/v0/grc1155"
)

var mintedBlockStore = newMintedBlockStore()

// MintedBlockStore owns token state, lifetime supply counters, inventory indexes,
// and canonical mint allowlist membership.
//
// Data shape:
// - token: GRC-1155 token state
// - supply: blockID(uint32) -> lifetime supply(int64)
// - userTokenIndex: user(address string) -> *Uint32BTreeSet(blockID)
// - mintAllowlist: blockID(uint32) -> map[address string]bool
//
// Non-responsibilities:
// - parse user-facing CSV input or validate external address string shape
// - perform auth, freeze, migration, payment, or event handling
type MintedBlockStore struct {
	token BlockGRC1155Token
	// supply tracks cumulative minted/reserved supply and is not decremented on burn.
	// It enforces lifetime maxSupply and mintable block delete policy.
	supply         *btree.Uint32BTree
	userTokenIndex *btree.StringBTree
	mintAllowlist  *btree.Uint32BTree
}

func newMintedBlockStore() *MintedBlockStore {
	return &MintedBlockStore{
		token:          grc1155.NewBasicGRC1155Token(""),
		supply:         btree.NewUint32BTree(32),
		userTokenIndex: btree.NewStringBTree(32),
		mintAllowlist:  btree.NewUint32BTree(32),
	}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable token/store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *MintedBlockStore) Token() BlockGRC1155Token {
	return s.token
}

func (s *MintedBlockStore) Supply() *btree.Uint32BTree {
	return s.supply
}

func (s *MintedBlockStore) UserTokenIndex() *btree.StringBTree {
	return s.userTokenIndex
}

func (s *MintedBlockStore) MintAllowlist() *btree.Uint32BTree {
	return s.mintAllowlist
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *MintedBlockStore) BalanceOf(user address, tokenID grc1155.TokenID) int64 {
	balance, err := s.token.BalanceOf(user, tokenID)
	if err != nil {
		panic("balanceOf failed: " + err.Error())
	}
	return balance
}

func (s *MintedBlockStore) BalanceOfBatch(ul []address, tokenIDs []grc1155.TokenID) []int64 {
	balanceBatch, err := s.token.BalanceOfBatch(ul, tokenIDs)
	if err != nil {
		panic("balanceOfBatch failed: " + err.Error())
	}
	return balanceBatch
}

func (s *MintedBlockStore) BalanceOfSafe(user address, tokenID grc1155.TokenID) (int64, bool) {
	balance, err := s.token.BalanceOf(user, tokenID)
	if err != nil {
		return 0, false
	}
	return balance, true
}

func (s *MintedBlockStore) IsApprovedForAll(owner, operator address) bool {
	return s.token.IsApprovedForAll(owner, operator)
}

func (s *MintedBlockStore) SetApprovalForAll(caller, operator address, approved bool) {
	err := s.token.SetApprovalForAll(caller, operator, approved)
	if err != nil {
		panic("setApprovalForAll failed: " + err.Error())
	}
}

func (s *MintedBlockStore) Transfer(caller, from, to address, tokenID grc1155.TokenID, amount int64) {
	err := s.token.SafeTransferFrom(caller, from, to, tokenID, amount)
	if err != nil {
		panic("transferFrom failed: " + err.Error())
	}

	blockID := tokenIDToBlockID(tokenID)
	s.addUserToken(to, blockID)
	s.removeUserToken(from, blockID)
}

func (s *MintedBlockStore) BatchTransfer(caller, from, to address, tokenIDs []grc1155.TokenID, amounts []int64) {
	err := s.token.SafeBatchTransferFrom(caller, from, to, tokenIDs, amounts)
	if err != nil {
		panic("batchTransferFrom failed: " + err.Error())
	}

	blockIDs := tokenIDsToBlockIDs(tokenIDs)
	s.addUserTokens(to, blockIDs)
	s.removeUserTokens(from, blockIDs)
}

func (s *MintedBlockStore) Mint(caller, to address, tokenID grc1155.TokenID, amount int64, maxSupply int64) {
	blockID := tokenIDToBlockID(tokenID)

	if s.exceedsSupply(blockID, amount, maxSupply) {
		panic("supply exceeded")
	}

	err := s.token.SafeMint(caller, to, tokenID, amount)
	if err != nil {
		panic("mint failed: " + err.Error())
	}

	nextSupply := s.SupplyOf(blockID) + amount
	s.supply.Set(blockID, nextSupply)
	s.addUserToken(to, blockID)
}

func (s *MintedBlockStore) Burn(caller, from address, tokenID grc1155.TokenID, amount int64) {
	err := s.token.Burn(caller, from, tokenID, amount)
	if err != nil {
		panic("burn failed: " + err.Error())
	}

	s.removeUserToken(from, tokenIDToBlockID(tokenID))
}

func (s *MintedBlockStore) BatchBurn(caller, from address, tokenIDs []grc1155.TokenID, amounts []int64) {
	err := s.token.BatchBurn(caller, from, tokenIDs, amounts)
	if err != nil {
		panic("batchBurn failed: " + err.Error())
	}

	s.removeUserTokens(from, tokenIDsToBlockIDs(tokenIDs))
}

func (s *MintedBlockStore) ListSupplies(tokenIDs ...grc1155.TokenID) []map[string]string {
	result := []map[string]string{}
	if len(tokenIDs) == 0 {
		return result
	}

	for _, tokenID := range tokenIDs {
		blockID := tokenIDToBlockID(tokenID)
		currentSupply, found := s.supply.Get(blockID)
		if !found {
			continue
		}

		result = append(result, map[string]string{
			"id":     string(tokenID),
			"supply": strconv.FormatInt(currentSupply.(int64), 10),
		})
	}
	return result
}

func (s *MintedBlockStore) SupplyTotal() int {
	return s.supply.Size()
}

func (s *MintedBlockStore) SupplyOf(blockID uint32) int64 {
	currentSupply, found := s.supply.Get(blockID)
	if !found {
		return 0
	}
	return currentSupply.(int64)
}

func (s *MintedBlockStore) exceedsSupply(blockID uint32, amount int64, maxSupply int64) bool {
	currentSupply := s.SupplyOf(blockID)
	if currentSupply > maxSupply {
		return true
	}
	return amount > maxSupply-currentSupply
}

func (s *MintedBlockStore) addUserToken(user address, blockID uint32) {
	tokens := s.getOrCreateUserTokenSet(user)
	tokens.Set(blockID)
}

func (s *MintedBlockStore) addUserTokens(user address, blockIDs []uint32) {
	tokens := s.getOrCreateUserTokenSet(user)
	for _, blockID := range blockIDs {
		tokens.Set(blockID)
	}
}

// removeUserToken only prunes the inventory index after balance reaches zero.
// Supply is a lifetime minted counter, so burn does not decrement it by policy.
func (s *MintedBlockStore) removeUserToken(user address, blockID uint32) {
	balance := s.BalanceOf(user, blockIDToTokenID(blockID))
	if balance != 0 {
		return
	}

	userStr := user.String()
	tokens, found := s.userTokenIndex.Get(userStr)
	if !found {
		return
	}

	tokensSet := tokens.(*btreeset.Uint32BTreeSet)
	tokensSet.Remove(blockID)
	if tokensSet.Size() == 0 {
		s.userTokenIndex.Remove(userStr)
	}
}

// removeUserTokens only prunes the inventory index after each balance reaches zero.
// Supply is a lifetime minted counter, so burn does not decrement it by policy.
func (s *MintedBlockStore) removeUserTokens(user address, blockIDs []uint32) {
	userStr := user.String()
	tokens, found := s.userTokenIndex.Get(userStr)
	if !found {
		return
	}

	tokensSet := tokens.(*btreeset.Uint32BTreeSet)
	for _, blockID := range blockIDs {
		balance := s.BalanceOf(user, blockIDToTokenID(blockID))
		if balance != 0 {
			continue
		}
		tokensSet.Remove(blockID)
	}
	if tokensSet.Size() == 0 {
		s.userTokenIndex.Remove(userStr)
	}
}

func (s *MintedBlockStore) getUserTokens(user address) []uint32 {
	userStr := user.String()
	tokens, found := s.userTokenIndex.Get(userStr)
	if !found {
		return []uint32{}
	}

	tokensSet := tokens.(*btreeset.Uint32BTreeSet)
	result := []uint32{}
	tokensSet.Iterate(nil, nil, func(blockID uint32) bool {
		result = append(result, blockID)
		return false
	})
	return result
}

func (s *MintedBlockStore) GetInventory(user address) []map[string]string {
	result := []map[string]string{}
	blockIDs := s.getUserTokens(user)
	for _, blockID := range blockIDs {
		blockIDStr := blockIDToString(blockID)
		balance := s.BalanceOf(user, blockIDToTokenID(blockID))
		if balance > 0 {
			result = append(result, map[string]string{
				"id":      blockIDStr,
				"balance": strconv.FormatInt(balance, 10),
			})
		}
	}
	return result
}

func (s *MintedBlockStore) UserInventoryTotal() int {
	return s.userTokenIndex.Size()
}

func (s *MintedBlockStore) SetMintAllowlist(blockID uint32, minters []address) {
	var mintersMap map[string]bool
	val, found := s.mintAllowlist.Get(blockID)
	if found {
		mintersMap = val.(map[string]bool)
	} else {
		mintersMap = make(map[string]bool)
	}

	for _, minter := range minters {
		mintersMap[minter.String()] = true
	}

	if !found {
		s.mintAllowlist.Set(blockID, mintersMap)
	}
}

func (s *MintedBlockStore) RemoveMintAllowlist(blockID uint32, minters []address) {
	blockIDStr := blockIDToString(blockID)

	val, found := s.mintAllowlist.Get(blockID)
	if !found {
		panic("mint allowlist not found: " + blockIDStr)
	}

	mintersMap := val.(map[string]bool)
	for _, minter := range minters {
		addrStr := minter.String()
		if !mintersMap[addrStr] {
			panic("minter not found in allowlist: " + addrStr)
		}
		delete(mintersMap, addrStr)
	}

	if len(mintersMap) == 0 {
		s.mintAllowlist.Remove(blockID)
	}
}

func (s *MintedBlockStore) GetMintAllowlist(blockID uint32) []string {
	val, found := s.mintAllowlist.Get(blockID)
	if !found {
		return []string{}
	}

	mintersMap := val.(map[string]bool)
	result := make([]string, 0, len(mintersMap))
	for addr := range mintersMap {
		result = append(result, addr)
	}
	return result
}

func (s *MintedBlockStore) CanUserMint(blockID uint32, caller address) bool {
	val, found := s.mintAllowlist.Get(blockID)
	if !found {
		return true
	}
	mintersMap := val.(map[string]bool)
	return mintersMap[caller.String()]
}

func (s *MintedBlockStore) MintAllowlistTotal() int {
	return s.mintAllowlist.Size()
}

func (s *MintedBlockStore) ClearMintAllowlist(blockID uint32) {
	s.mintAllowlist.Remove(blockID)
}

func (s *MintedBlockStore) getOrCreateUserTokenSet(user address) *btreeset.Uint32BTreeSet {
	userStr := user.String()
	tokens, found := s.userTokenIndex.Get(userStr)
	if found {
		return tokens.(*btreeset.Uint32BTreeSet)
	}

	tokensSet := btreeset.NewUint32BTreeSet(32)
	s.userTokenIndex.Set(userStr, tokensSet)
	return tokensSet
}
