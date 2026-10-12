package equipment

import (
	"chain/runtime/unsafe"
	"net/url"
	"strconv"
	"time"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/akkadia/beta/grc721"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/akkadia/beta/admin"
)

const (
	definitionIDKey            = "definitionId"
	tokenIDKey                 = "tokenId"
	createdAtKey               = "created_at"
	maxEquipmentTokenID uint64 = 18446744073709551615
)

var (
	equipmentToken    = grc721.NewBasicNFT("Akkadia Equipment", "AEQP")
	equipmentMetadata *bptree.BPTree
	ownerTokenIDs     *bptree.BPTree
	latestTokenID     uint64
)

func init() { resetEquipmentState() }

func resetEquipmentState() {
	equipmentToken = grc721.NewBasicNFT("Akkadia Equipment", "AEQP")
	equipmentMetadata = bptree.NewBPTree32()
	ownerTokenIDs = bptree.NewBPTree32()
	minterRealms = bptree.NewBPTree32()
	listLimit = 100
	latestTokenID = 0
}

func Mint(cur realm, recipient address, definitionID uint32, attrKeys, attrValues string) uint64 {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertEquipmentNoCoins()
	return mintEquipment(cross(cur), recipient, definitionID, attrKeys, attrValues)
}

func MintFromRealm(cur realm, recipient address, definitionID uint32, attrKeys, attrValues string) uint64 {
	mustGetMinterRealmCaller(0, cur)
	if unsafe.OriginCaller() != recipient {
		panic("equipment recipient must be origin caller")
	}
	return mintEquipment(cross(cur), recipient, definitionID, attrKeys, attrValues)
}

func GetMetadata(tokenID uint64) map[string]string {
	return copyStringMap(mustGetEquipmentMetadata(tokenID))
}

func SetMetadata(cur realm, tokenID uint64, attrKeys, attrValues string) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertEquipmentNoCoins()
	setEquipmentMetadata(tokenID, attrKeys, attrValues)
}

func SetMetadataFromRealm(cur realm, tokenID uint64, attrKeys, attrValues string) {
	mustGetMinterRealmCaller(0, cur)
	if unsafe.OriginCaller() != OwnerOf(tokenID) {
		panic("equipment owner must be origin caller")
	}
	setEquipmentMetadata(tokenID, attrKeys, attrValues)
}

func GetOwnedCount(owner address) int {
	if !owner.IsValid() {
		panic("invalid equipment owner")
	}
	ids, found := getOwnerTokenIDs(owner)
	if !found {
		return 0
	}
	return ids.Size()
}

func ListByOwner(owner address, page, count int) []map[string]string {
	if !owner.IsValid() {
		panic("invalid equipment owner")
	}
	assertEquipmentListPageCount(page, count)
	ids, found := getOwnerTokenIDs(owner)
	if !found {
		return []map[string]string{}
	}
	result := []map[string]string{}
	ids.IterateByOffset((page-1)*count, count, func(key string, _ any) bool {
		tokenID := parseUint64Key(key)
		row := GetMetadata(tokenID)
		row[tokenIDKey] = strconv.FormatUint(tokenID, 10)
		result = append(result, row)
		return false
	})
	return result
}

func Name() string   { return equipmentToken.Name() }
func Symbol() string { return equipmentToken.Symbol() }

func OwnerOf(tokenID uint64) address {
	owner, err := equipmentToken.OwnerOf(equipmentTokenID(tokenID))
	if err != nil {
		panic("equipment owner query failed: " + err.Error())
	}
	return owner
}

func Has(tokenID uint64) bool {
	_, err := equipmentToken.OwnerOf(equipmentTokenID(tokenID))
	return err == nil
}

func GetLatestTokenID() uint64 {
	return latestTokenID
}

func BalanceOf(owner address) int64 {
	if !owner.IsValid() {
		panic("invalid equipment owner")
	}
	balance, err := equipmentToken.BalanceOf(owner)
	if err != nil {
		panic("equipment balance query failed: " + err.Error())
	}
	return balance
}

func GetApproved(tokenID uint64) address {
	approved, err := equipmentToken.GetApproved(equipmentTokenID(tokenID))
	if err != nil {
		panic("equipment approval query failed: " + err.Error())
	}
	return approved
}

func IsApprovedForAll(owner, operator address) bool {
	return equipmentToken.IsApprovedForAll(owner, operator)
}

func Approve(cur realm, operator address, tokenID uint64) {
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertEquipmentNoCoins()
	if err := equipmentToken.Approve(caller, operator, equipmentTokenID(tokenID)); err != nil {
		panic("equipment approval failed: " + err.Error())
	}
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertEquipmentNoCoins()
	if err := equipmentToken.SetApprovalForAll(caller, operator, approved); err != nil {
		panic("equipment operator approval failed: " + err.Error())
	}
}

func TransferFrom(cur realm, from, to address, tokenID uint64) {
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertEquipmentNoCoins()
	if err := equipmentToken.TransferFrom(caller, from, to, equipmentTokenID(tokenID)); err != nil {
		panic("equipment transfer failed: " + err.Error())
	}
	if from != to {
		removeOwnerTokenID(from, tokenID)
		addOwnerTokenID(to, tokenID)
	}
}

func Burn(cur realm, tokenID uint64) {
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertEquipmentNoCoins()
	owner := OwnerOf(tokenID)
	approved, err := equipmentToken.GetApproved(equipmentTokenID(tokenID))
	if caller != owner && !equipmentToken.IsApprovedForAll(owner, caller) && (err != nil || approved != caller) {
		panic("equipment owner or approved operator required")
	}
	burnEquipment(tokenID, owner)
}

func BurnFromRealm(cur realm, tokenID uint64) {
	mustGetMinterRealmCaller(0, cur)
	owner := OwnerOf(tokenID)
	if unsafe.OriginCaller() != owner {
		panic("equipment owner must be origin caller")
	}
	burnEquipment(tokenID, owner)
}

func mintEquipment(cur realm, recipient address, definitionID uint32, attrKeys, attrValues string) uint64 {
	if !recipient.IsValid() || recipient == cur.Address() {
		panic("invalid equipment recipient")
	}
	attrs := parseEquipmentAttributes(attrKeys, attrValues)
	tokenID := allocateTokenID()
	if err := equipmentToken.Mint(recipient, equipmentTokenID(tokenID)); err != nil {
		panic("equipment mint failed: " + err.Error())
	}
	attrs[definitionIDKey] = strconv.FormatUint(uint64(definitionID), 10)
	attrs[createdAtKey] = strconv.FormatInt(time.Now().Unix(), 10)
	equipmentMetadata.Set(uint64Key(tokenID), attrs)
	addOwnerTokenID(recipient, tokenID)
	return tokenID
}

func allocateTokenID() uint64 {
	if latestTokenID == maxEquipmentTokenID {
		panic("equipment token id exhausted")
	}
	latestTokenID++
	return latestTokenID
}

func mustGetEquipmentMetadata(tokenID uint64) map[string]string {
	value := equipmentMetadata.Get(uint64Key(tokenID))
	if value == nil {
		panic("equipment metadata not found: " + strconv.FormatUint(tokenID, 10))
	}
	return value.(map[string]string)
}

func setEquipmentMetadata(tokenID uint64, attrKeys, attrValues string) {
	current := mustGetEquipmentMetadata(tokenID)
	attrs := parseEquipmentAttributes(attrKeys, attrValues)
	attrs[definitionIDKey] = current[definitionIDKey]
	attrs[createdAtKey] = current[createdAtKey]
	equipmentMetadata.Set(uint64Key(tokenID), attrs)
}

func parseEquipmentAttributes(attrKeys, attrValues string) map[string]string {
	attrs := parseAttributesCSV(attrKeys, attrValues)
	if _, found := attrs[definitionIDKey]; found {
		panic("reserved key: " + definitionIDKey)
	}
	if _, found := attrs[tokenIDKey]; found {
		panic("reserved key: " + tokenIDKey)
	}
	if _, found := attrs[createdAtKey]; found {
		panic("reserved key: " + createdAtKey)
	}
	return attrs
}

func burnEquipment(tokenID uint64, owner address) {
	if err := equipmentToken.Burn(equipmentTokenID(tokenID)); err != nil {
		panic("equipment burn failed: " + err.Error())
	}
	if _, removed := equipmentMetadata.Remove(uint64Key(tokenID)); !removed {
		panic("equipment metadata not found: " + strconv.FormatUint(tokenID, 10))
	}
	removeOwnerTokenID(owner, tokenID)
}

func mustGetMinterRealmCaller(_ int, rlm realm) address {
	accesscontrol.AssertCurrentRealm(0, rlm)
	prev := rlm.Previous()
	if prev.IsUserCall() {
		panic("user calls not allowed: function must be called by a realm")
	}
	caller := prev.Address()
	if !IsMinterRealm(caller) {
		panic("minter realm required")
	}
	return caller
}

func assertEquipmentNoCoins() {
	if len(unsafe.OriginSend()) != 0 {
		panic("attached coins not allowed")
	}
}

func assertEquipmentListPageCount(page, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 {
		panic("count must be at least 1")
	}
	if count > listLimit {
		panic("count exceeds listLimit (max: " + strconv.Itoa(listLimit) + ")")
	}
}

func addOwnerTokenID(owner address, tokenID uint64) {
	value := ownerTokenIDs.Get(owner.String())
	var ids *bptree.BPTree
	if value != nil {
		ids = value.(*bptree.BPTree)
	} else {
		ids = bptree.NewBPTree32()
		ownerTokenIDs.Set(owner.String(), ids)
	}
	ids.Set(uint64Key(tokenID), true)
}

func removeOwnerTokenID(owner address, tokenID uint64) {
	ids, found := getOwnerTokenIDs(owner)
	if !found {
		return
	}
	ids.Remove(uint64Key(tokenID))
}

func getOwnerTokenIDs(owner address) (*bptree.BPTree, bool) {
	value := ownerTokenIDs.Get(owner.String())
	if value == nil {
		return nil, false
	}
	return value.(*bptree.BPTree), true
}

func equipmentTokenID(tokenID uint64) grc721.TokenID {
	return grc721.TokenID(strconv.FormatUint(tokenID, 10))
}

func uint64Key(id uint64) string {
	s := strconv.FormatUint(id, 10)
	if len(s) >= 20 {
		return s
	}
	return "00000000000000000000"[len(s):] + s
}

func parseUint64Key(key string) uint64 {
	id, err := strconv.ParseUint(key, 10, 64)
	if err != nil {
		panic("invalid uint64 key: " + key)
	}
	return id
}

func copyStringMap(source map[string]string) map[string]string {
	result := map[string]string{}
	for key, value := range source {
		result[key] = value
	}
	return result
}

// parseAttributesCSV accepts comma-separated keys and URL-encoded values.
// Empty keys and values produce an empty attribute map so mint can store
// definitionId and created_at alone.
func parseAttributesCSV(keys, values string) map[string]string {
	if keys == "" && values == "" {
		return map[string]string{}
	}

	result := map[string]string{}
	keyStart, valStart := 0, 0
	keyIdx, valIdx := 0, 0
	for {
		for keyIdx < len(keys) && keys[keyIdx] != ',' {
			keyIdx++
		}
		for valIdx < len(values) && values[valIdx] != ',' {
			valIdx++
		}

		key := keys[keyStart:keyIdx]
		if key == "" {
			panic("attributes key must be not empty")
		}
		if _, found := result[key]; found {
			panic("attributes key duplicated: " + key)
		}

		value, err := url.PathUnescape(values[valStart:valIdx])
		if err != nil {
			panic("attributes value URL decode failed: " + key)
		}
		result[key] = value

		keyEnd := keyIdx >= len(keys)
		valEnd := valIdx >= len(values)
		if keyEnd != valEnd {
			panic("attributes keys and values count mismatch")
		}
		if keyEnd {
			break
		}

		keyIdx++
		valIdx++
		keyStart = keyIdx
		valStart = valIdx
	}

	return result
}
