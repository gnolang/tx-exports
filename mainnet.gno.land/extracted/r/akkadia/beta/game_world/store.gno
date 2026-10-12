package game_world

import (
	"strconv"

	"gno.land/p/nt/bptree/v0"
)

var (
	gameWorlds             *bptree.BPTree = bptree.NewBPTree32()
	ownerGameWorldIDs      *bptree.BPTree = bptree.NewBPTree32()
	restrictedGameWorldIDs *bptree.BPTree = bptree.NewBPTree32()
	latestGameWorldID      uint64
)

func addOwnerGameWorldID(owner address, gameWorldID uint64) {
	value := ownerGameWorldIDs.Get(owner.String())
	var ids *bptree.BPTree
	if value != nil {
		ids = value.(*bptree.BPTree)
	} else {
		ids = bptree.NewBPTree32()
		ownerGameWorldIDs.Set(owner.String(), ids)
	}
	ids.Set(uint64Key(gameWorldID), true)
}

func removeOwnerGameWorldID(owner address, gameWorldID uint64) {
	ids, found := getOwnerGameWorldIDs(owner)
	if !found {
		return
	}
	ids.Remove(uint64Key(gameWorldID))
}

func getOwnerGameWorldIDs(owner address) (*bptree.BPTree, bool) {
	value := ownerGameWorldIDs.Get(owner.String())
	if value == nil {
		return nil, false
	}
	return value.(*bptree.BPTree), true
}

func resetGameWorldStore() {
	gameWorlds = bptree.NewBPTree32()
	ownerGameWorldIDs = bptree.NewBPTree32()
	restrictedGameWorldIDs = bptree.NewBPTree32()
	latestGameWorldID = 0
}

func uint64Key(id uint64) string {
	// Zero-pad so BPTree key order matches numeric ID order.
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
