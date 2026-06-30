package ulnbase

import (
	"encoding/binary"

	"gno.land/p/nt/avl/v0"
)

type configStore struct {
	tree avl.Tree
}

func (s *configStore) get(oapp address, remoteEid uint32) (*UlnConfig, bool) {
	key := ulnConfigKey(oapp, remoteEid)
	v, ok := s.tree.Get(key)
	if !ok {
		return nil, false
	}
	return v.(*UlnConfig), true
}

func (s *configStore) set(oapp address, remoteEid uint32, config *UlnConfig) bool {
	key := ulnConfigKey(oapp, remoteEid)
	return s.tree.Set(key, config)
}

func ulnConfigKey(oapp address, remoteEid uint32) string {
	bz := make([]byte, 4+len(oapp))
	binary.BigEndian.PutUint32(bz, remoteEid)
	copy(bz[4:], oapp)
	return string(bz)
}
