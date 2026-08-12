package pixeltargettest1

import (
	"strconv"
	"strings"

	unsaferealm "chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
)

const collectionOwner address = "g1j2adx6ngvawtmkhq7eexsk9uq4u9zsrealpye2"

var officialTarget avl.Tree

func key(x, y int64) string {
	return strconv.FormatInt(x, 10) + "," + strconv.FormatInt(y, 10)
}

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("owner-only")
	}
}

func SetOfficialTarget(cur realm, encoded string) {
	assertOwner()
	if encoded == "" {
		return
	}
	for _, entry := range strings.Split(encoded, ";") {
		parts := strings.SplitN(entry, ",", 3)
		if len(parts) != 3 {
			panic("malformed entry: " + entry)
		}
		x, err1 := strconv.ParseInt(parts[0], 10, 64)
		y, err2 := strconv.ParseInt(parts[1], 10, 64)
		c, err3 := strconv.ParseInt(parts[2], 10, 64)
		if err1 != nil || err2 != nil || err3 != nil {
			panic("malformed entry: " + entry)
		}
		officialTarget.Set(key(x, y), c)
	}
}

func ClearOfficialTarget(cur realm) {
	assertOwner()
	officialTarget = avl.Tree{}
}

func IsOfficialTarget(x, y, colorIndex int64) bool {
	c, ok := officialTarget.Get(key(x, y)).(int64)
	return ok && c == colorIndex
}

func TargetSize() int64 {
	n := int64(0)
	officialTarget.Iterate("", "", func(k string, v any) bool {
		n++
		return false
	})
	return n
}

func Render(path string) string { return "ok" }
