package minttest1

import (
	"strconv"

	"gno.land/p/nt/avl/v0"
)

var (
	presets avl.Tree
	tokens  avl.Tree
	presetsIn, presetsOut, nextID int64
)

func AddPreset(cur realm, payload string) {
	presets.Set(strconv.FormatInt(presetsIn, 10), payload)
	presetsIn++
}

func Mint(cur realm) string {
	key := strconv.FormatInt(presetsOut, 10)
	payload, ok := presets.Get(key).(string)
	if !ok {
		panic("empty queue")
	}
	presets.Remove(key)
	presetsOut++
	tokens.Set(strconv.FormatInt(nextID, 10), payload)
	nextID++
	return payload
}

func Render(path string) string { return "ok" }
