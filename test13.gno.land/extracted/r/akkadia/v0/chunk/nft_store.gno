package chunk

import (
	"gno.land/p/akkadia/v0/ds/btree"
	"gno.land/p/akkadia/v0/ds/btreeset"
	"gno.land/p/akkadia/v0/grc721"
	"gno.land/p/nt/bptree/v0"
)

var nft = grc721.NewBasicNFT("Akkadia Chunk", "AKC")
var nftStore = newNFTStore(nft)

// NFTStore owns chunk token storage access and token-owned secondary indexes.
//
// Data shape:
// - token: GRC-721 token state
// - metadataByWorldID: worldID(uint32) -> *StringBTree(tokenID(string) -> metadata(string))
// - ownerIndexByWorld: worldID(string) -> *BPTree(owner(address string) -> *StringBTreeSet(tokenID))
//
// Responsibilities:
// - delegate GRC-721 token reads and writes to the package-owned token
// - keep chunk metadata and owner-token indexes in sync with token mutations
// - protect store-owned invariants such as duplicate metadata rows for the same token ID
// - return newly allocated result slices and maps from public read methods
//
// Non-responsibilities:
// - validate external parameter shape such as world type, hash, verifier, coordinates, or pagination
// - perform auth, freeze, migration, payment, or event handling
// - check world existence or higher-level ownership rules outside token transfer semantics
// - build or parse token, chunk, or coordinate keys; public exported functions must pass canonical raw keys
// - parse user-facing encoded input; public exported functions must pass canonical values
type NFTStore struct {
	token ChunkGRC721Token
	// Chunk metadata is stored as one encoded string, not a map, to avoid
	// dirtying and storing per-field map objects on metadata writes.
	metadataByWorldID *btree.Uint32BTree
	ownerIndexByWorld *bptree.BPTree
}

func newNFTStore(token ChunkGRC721Token) *NFTStore {
	return &NFTStore{
		token:             token,
		metadataByWorldID: btree.NewUint32BTree(32),
		ownerIndexByWorld: bptree.NewBPTree32(),
	}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable token/store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *NFTStore) Token() ChunkGRC721Token {
	return s.token
}

func (s *NFTStore) MetadataByWorldID() *btree.Uint32BTree {
	return s.metadataByWorldID
}

func (s *NFTStore) OwnerIndexByWorld() *bptree.BPTree {
	return s.ownerIndexByWorld
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *NFTStore) Name() string {
	return s.token.Name()
}

func (s *NFTStore) Symbol() string {
	return s.token.Symbol()
}

func (s *NFTStore) TokenCount() int64 {
	return s.token.TokenCount()
}

func (s *NFTStore) BalanceOf(user address) (int64, error) {
	return s.token.BalanceOf(user)
}

func (s *NFTStore) OwnerOf(tokenID grc721.TokenID) (address, error) {
	return s.token.OwnerOf(tokenID)
}

func (s *NFTStore) OwnerOfSafe(tokenID grc721.TokenID) (address, bool) {
	owner, err := s.token.OwnerOf(tokenID)
	if err != nil {
		return "", false
	}
	return owner, true
}

func (s *NFTStore) IsApprovedForAll(owner address, user address) bool {
	return s.token.IsApprovedForAll(owner, user)
}

func (s *NFTStore) GetApproved(tokenID grc721.TokenID) (address, error) {
	return s.token.GetApproved(tokenID)
}

func (s *NFTStore) Approve(caller address, user address, tokenID grc721.TokenID) error {
	return s.token.Approve(caller, user, tokenID)
}

func (s *NFTStore) SetApprovalForAll(caller address, user address, approved bool) error {
	return s.token.SetApprovalForAll(caller, user, approved)
}

func (s *NFTStore) Mint(to address, tokenID grc721.TokenID, worldID uint32, metadata string) error {
	if err := s.token.Mint(to, tokenID); err != nil {
		return err
	}
	s.addOwnerIndex(worldID, to, tokenID)
	s.CreateMetadata(worldID, tokenID, metadata)
	return nil
}

func (s *NFTStore) Transfer(caller address, from address, to address, tokenID grc721.TokenID, worldID uint32) error {
	if err := s.token.TransferFrom(caller, from, to, tokenID); err != nil {
		return err
	}
	s.removeOwnerIndex(worldID, from, tokenID)
	s.addOwnerIndex(worldID, to, tokenID)
	return nil
}

func (s *NFTStore) ListOwners(tokenIDs ...grc721.TokenID) []map[string]string {
	result := []map[string]string{}
	if len(tokenIDs) == 0 {
		return result
	}
	for _, tokenID := range tokenIDs {
		owner, err := s.token.OwnerOf(tokenID)
		if err != nil {
			continue
		}
		result = append(result, map[string]string{"id": string(tokenID), "owner": string(owner)})
	}
	return result
}

func (s *NFTStore) CreateMetadata(worldID uint32, tokenID grc721.TokenID, metadata string) {
	t := s.getOrCreateMetadataTree(worldID)
	_, exists := t.Get(string(tokenID))
	if exists {
		panic("metadata already exists: " + string(tokenID))
	}
	t.Set(string(tokenID), metadata)
}

func (s *NFTStore) SetChunkMetadata(worldID uint32, tokenID grc721.TokenID, metadata string) {
	if _, found := s.OwnerOfSafe(tokenID); !found {
		panic("token not found: " + string(tokenID))
	}
	t := s.getOrCreateMetadataTree(worldID)
	t.Set(string(tokenID), metadata)
}

func (s *NFTStore) GetChunkMetadata(worldID uint32, tokenID grc721.TokenID) map[string]string {
	value, exists := s.metadataByWorldID.Get(worldID)
	if !exists {
		return nil
	}
	t := value.(*btree.StringBTree)
	result, found := t.Get(string(tokenID))
	if !found {
		return nil
	}
	return map[string]string{
		"id":       string(tokenID),
		"metadata": result.(string),
	}
}

func (s *NFTStore) ListChunkMetadataByWorld(worldID uint32, page int, count int) []map[string]string {
	value, exists := s.metadataByWorldID.Get(worldID)
	if !exists {
		return []map[string]string{}
	}
	t := value.(*btree.StringBTree)
	result := []map[string]string{}
	offset := (page - 1) * count
	t.IterateByOffset(offset, count, func(key string, value any) bool {
		result = append(result, map[string]string{
			"id":       key,
			"metadata": value.(string),
		})
		return false
	})
	return result
}

func (s *NFTStore) WorldMetadataSize(worldID uint32) int {
	value, exists := s.metadataByWorldID.Get(worldID)
	if !exists {
		return 0
	}
	return value.(*btree.StringBTree).Size()
}

func (s *NFTStore) MetadataWorldSize() int {
	return s.metadataByWorldID.Size()
}

func (s *NFTStore) ListTokenIDsByOwner(worldID uint32, owner address, page int, count int) []string {
	tree := s.getOwnerTokenTree(worldID, owner)
	if tree == nil {
		return []string{}
	}
	result := []string{}
	offset := (page - 1) * count
	tree.IterateByOffset(offset, count, func(tokenID string) bool {
		result = append(result, tokenID)
		return false
	})
	return result
}

func (s *NFTStore) OwnerTokenSize(worldID uint32, owner address) int {
	tree := s.getOwnerTokenTree(worldID, owner)
	if tree == nil {
		return 0
	}
	return tree.Size()
}

func (s *NFTStore) OwnerWorldSize() int {
	return s.ownerIndexByWorld.Size()
}

func (s *NFTStore) getOrCreateMetadataTree(worldID uint32) *btree.StringBTree {
	value, exists := s.metadataByWorldID.Get(worldID)
	if !exists {
		t := btree.NewStringBTree(32)
		s.metadataByWorldID.Set(worldID, t)
		return t
	}
	return value.(*btree.StringBTree)
}

func (s *NFTStore) addOwnerIndex(worldID uint32, owner address, tokenID grc721.TokenID) {
	tree := s.getOrCreateOwnerTokenTree(worldID, owner)
	tree.Set(string(tokenID))
}

func (s *NFTStore) removeOwnerIndex(worldID uint32, owner address, tokenID grc721.TokenID) {
	wKey := formatWorldID(worldID)
	val, exists := s.ownerIndexByWorld.Get(wKey)
	if !exists {
		return
	}
	ownerTree := val.(*bptree.BPTree)
	coordVal, found := ownerTree.Get(owner.String())
	if !found {
		return
	}
	tokenTree := coordVal.(*btreeset.StringBTreeSet)
	tokenTree.Remove(string(tokenID))
}

func (s *NFTStore) getOwnerTokenTree(worldID uint32, owner address) *btreeset.StringBTreeSet {
	wKey := formatWorldID(worldID)
	val, exists := s.ownerIndexByWorld.Get(wKey)
	if !exists {
		return nil
	}
	ownerTree := val.(*bptree.BPTree)
	coordVal, found := ownerTree.Get(owner.String())
	if !found {
		return nil
	}
	return coordVal.(*btreeset.StringBTreeSet)
}

func (s *NFTStore) getOrCreateOwnerTokenTree(worldID uint32, owner address) *btreeset.StringBTreeSet {
	wKey := formatWorldID(worldID)
	ownerKey := owner.String()
	var ownerTree *bptree.BPTree
	val, exists := s.ownerIndexByWorld.Get(wKey)
	if !exists {
		ownerTree = bptree.NewBPTree32()
		s.ownerIndexByWorld.Set(wKey, ownerTree)
	} else {
		ownerTree = val.(*bptree.BPTree)
	}
	coordVal, found := ownerTree.Get(ownerKey)
	if !found {
		tokenTree := btreeset.NewStringBTreeSet(32)
		ownerTree.Set(ownerKey, tokenTree)
		return tokenTree
	}
	return coordVal.(*btreeset.StringBTreeSet)
}
