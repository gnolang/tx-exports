package user

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btree"

// UserStore owns user records, opaque metadata, and address/nickname indexes.
//
// Data shape:
// - metadatas: userID(uint32) -> metadata(string)
// - properties: userID(uint32) -> map[string]string
// - userMap: userID(uint32) -> address(string)
// - addressIDs: address(string) -> userID(uint32)
// - nicknames: userID(uint32) -> nickname(string)
// - nicknameIDs: nickname(string) -> userID(uint32)
type UserStore struct {
	metadatas   *btree.Uint32BTree
	properties  *btree.Uint32BTree
	userMap     *btree.Uint32BTree
	addressIDs  *btree.StringBTree
	nicknames   *btree.Uint32BTree
	nicknameIDs *btree.StringBTree
	nextUserID  uint32
}

var userStore = newUserStore()

func newUserStore() *UserStore {
	return &UserStore{
		metadatas:   btree.NewUint32BTree(32),
		properties:  btree.NewUint32BTree(32),
		userMap:     btree.NewUint32BTree(32),
		addressIDs:  btree.NewStringBTree(32),
		nicknames:   btree.NewUint32BTree(32),
		nicknameIDs: btree.NewStringBTree(32),
		nextUserID:  1,
	}
}

func (s *UserStore) Has(addr address) bool {
	_, found := s.addressIDs.Get(addr.String())
	return found
}

func (s *UserStore) Create(addr address, props map[string]string) {
	addrStr := addr.String()
	s.assertNotExists(addrStr)
	nickname := props["nickname"]
	s.assertNicknameAvailable(nickname)

	id := s.createID(addr)
	s.setNickname(id, nickname)
	s.properties.Set(id, copyStringMap(props))
}

func (s *UserStore) Update(addr address, props map[string]string) map[string]string {
	addrStr := addr.String()
	s.assertExists(addrStr)

	id := s.getID(addr)
	currentVal, found := s.properties.Get(id)
	if !found {
		panic("user properties not found: " + addrStr)
	}

	if nickname, found := props["nickname"]; found {
		currentNickname := s.getNickname(id)
		if currentNickname != nickname {
			s.assertNicknameAvailable(nickname)
			s.unsetNickname(id)
			s.setNickname(id, nickname)
		}
	}

	current := currentVal.(map[string]string)
	for key, value := range props {
		current[key] = value
	}
	s.properties.Set(id, current)
	return copyStringMap(current)
}

func (s *UserStore) Delete(addr address) {
	addrStr := addr.String()
	s.assertExists(addrStr)

	id := s.getID(addr)
	s.unsetNickname(id)
	s.userMap.Remove(id)
	s.addressIDs.Remove(addrStr)
	s.metadatas.Remove(id)
	s.properties.Remove(id)
}

func (s *UserStore) SetMetadata(addr address, metadata string) {
	id := s.getID(addr)
	s.metadatas.Set(id, metadata)
}

func (s *UserStore) Total() int {
	return s.userMap.Size()
}

func (s *UserStore) NextID() uint32 {
	return s.nextUserID
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *UserStore) Metadatas() *btree.Uint32BTree {
	return s.metadatas
}

func (s *UserStore) Properties() *btree.Uint32BTree {
	return s.properties
}

func (s *UserStore) UserMap() *btree.Uint32BTree {
	return s.userMap
}

func (s *UserStore) AddressIDs() *btree.StringBTree {
	return s.addressIDs
}

func (s *UserStore) Nicknames() *btree.Uint32BTree {
	return s.nicknames
}

func (s *UserStore) NicknameIDs() *btree.StringBTree {
	return s.nicknameIDs
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *UserStore) List(page, count int) []string {
	result := make([]string, 0)
	offset := (page - 1) * count

	s.userMap.IterateByOffset(offset, count, func(id uint32, val interface{}) bool {
		result = append(result, val.(string))
		return false
	})

	return result
}

func (s *UserStore) AddressByNickname(nickname string) address {
	v, found := s.nicknameIDs.Get(nickname)
	if !found {
		panic("user not found")
	}
	return s.addressByID(v.(uint32))
}

func (s *UserStore) HasNickname(nickname string) bool {
	_, found := s.nicknameIDs.Get(nickname)
	return found
}

func (s *UserStore) NicknameByAddress(addr address) string {
	id, found := s.findID(addr.String())
	if !found {
		return ""
	}
	return s.getNickname(id)
}

func (s *UserStore) ListUserMetadataByAddresses(addrs ...address) []string {
	result := []string{}
	for _, addr := range addrs {
		id, userFound := s.findID(addr.String())
		if !userFound {
			result = append(result, "")
			continue
		}
		metadata, found := s.metadatas.Get(id)
		if !found {
			result = append(result, "")
			continue
		}
		result = append(result, metadata.(string))
	}
	return result
}

func (s *UserStore) ListUsersByAddresses(addrs ...address) []map[string]string {
	result := []map[string]string{}
	for _, addr := range addrs {
		addrStr := addr.String()
		id, userFound := s.findID(addrStr)
		if !userFound {
			continue
		}
		props, found := s.properties.Get(id)
		if !found {
			continue
		}
		m := copyStringMap(props.(map[string]string))
		m["address"] = addrStr
		result = append(result, m)
	}
	return result
}

func (s *UserStore) assertNotExists(addrStr string) {
	_, found := s.addressIDs.Get(addrStr)
	if found {
		panic("user already exists: " + addrStr)
	}
}

func (s *UserStore) assertExists(addrStr string) {
	_, found := s.addressIDs.Get(addrStr)
	if !found {
		panic("user not found: " + addrStr)
	}
}

func (s *UserStore) assertNicknameAvailable(nickname string) {
	_, taken := s.nicknameIDs.Get(nickname)
	if taken {
		panic("nickname already exists: " + nickname)
	}
}

func (s *UserStore) createID(addr address) uint32 {
	id := s.nextUserID
	s.nextUserID++
	s.userMap.Set(id, addr.String())
	s.addressIDs.Set(addr.String(), id)
	return id
}

func (s *UserStore) findID(addrStr string) (uint32, bool) {
	v, found := s.addressIDs.Get(addrStr)
	if !found {
		return 0, false
	}
	return v.(uint32), true
}

func (s *UserStore) getID(addr address) uint32 {
	addrStr := addr.String()
	id, found := s.findID(addrStr)
	if !found {
		panic("user not found: " + addrStr)
	}
	return id
}

func (s *UserStore) addressByID(id uint32) address {
	v, found := s.userMap.Get(id)
	if !found {
		panic("user not found")
	}
	return address(v.(string))
}

func (s *UserStore) getNickname(id uint32) string {
	v, found := s.nicknames.Get(id)
	if !found {
		return ""
	}
	return v.(string)
}

func (s *UserStore) setNickname(id uint32, nickname string) {
	s.nicknames.Set(id, nickname)
	s.nicknameIDs.Set(nickname, id)
}

func (s *UserStore) unsetNickname(id uint32) {
	oldNick, found := s.nicknames.Get(id)
	if !found {
		return
	}
	s.nicknames.Remove(id)
	s.nicknameIDs.Remove(oldNick.(string))
}
